# Terminal emulators (OSC 11 & DEC mode 2031)

The "platform" with no window-system connection, no session bus and no user
defaults — where the only peer that knows what the text will look like is the
emulator on the other end of the pty. This is the sink
[`hue`](../../../specs/hue/index.md) uses most, in both its ANSI and
[TUI](../../../specs/hue/tui.md) modes.

|                     |                                                                                   |
| ------------------- | --------------------------------------------------------------------------------- |
| Preference surface  | color scheme (dark/light) · background & foreground colors · the 16-color palette |
| Canonical API       | **DEC private mode 2031** — `CSI ? 996 n` query, `CSI ? 997 ; Ps n` reply         |
| Legacy API          | **OSC 11** background query · the `COLORFGBG` environment variable                |
| Change notification | **push** — `CSI ? 2031 h` enables unsolicited `CSI ? 997 n` on change             |
| Palette derivation  | none; the terminal's palette _is_ the app's palette for indexed colors            |
| Accent / contrast   | **neither exists**                                                                |
| Runnable example    | [`examples/color-scheme-probe.d`](./examples/color-scheme-probe.d)                |

## Overview

### What it solves

A terminal application inherits its colors from the emulator, and until recently
had no way to ask what they were. The workarounds were all inference: parse
`COLORFGBG`, query the background with OSC 11 and guess from its luminance, or
give up and let the user pass `--theme`. All three are wrong in a way that
matters — when the user switches their system to dark mode at dusk, a running
`vim`, `bat` or `hue` keeps painting for the old scheme until it is restarted.

**DEC private mode 2031** fixes exactly that, and it is the newest and most
directly relevant capability in this whole survey: it gives a terminal
application the same _semantic answer plus change notification_ that
[GNOME](../gnome/index.md) gives a desktop application.

### Design philosophy

The design is deliberately two-part, because the two parts solve different
problems:

- **A query** (`CSI ? 996 n`) answers "what is it now" — a DSR in the established
  style, so it costs one round trip and needs no mode change.
- **A mode** (`CSI ? 2031 h`) opts into _unsolicited_ notifications, so a
  long-running full-screen application never polls.

Crucially the notification carries **no value**: on a change the terminal sends
`CSI ? 997 n`, and the application re-queries. That is the same
"notification means re-read" contract every other platform in this survey
converged on ([concepts](../concepts.md#push-vs-poll)) — arrived at
independently, by people writing an escape-sequence spec.

## How it works

### The sequences

| Sequence          | Direction | Meaning                                      |
| ----------------- | --------- | -------------------------------------------- |
| `CSI ? 2031 h`    | → term    | DECSET: enable color-scheme change reporting |
| `CSI ? 2031 l`    | → term    | DECRST: disable it                           |
| `CSI ? 996 n`     | → term    | DSR: what is the color scheme?               |
| `CSI ? 997 ; 1 n` | ← term    | reply: **dark**                              |
| `CSI ? 997 ; 2 n` | ← term    | reply: **light**                             |
| `CSI ? 997 n`     | ← term    | unsolicited: it changed — re-query           |

Support is broad and recent: Contour (which originated the extension), foot
1.23+, Ghostty 1.0+, kitty, iTerm2, VTE, tmux 3.6+, and xterm.js. `xterm` itself
does not implement it, which sets the floor for a fallback.

### OSC 11, the fallback

`OSC 11 ; ? ST` asks for the background color; the reply is
`OSC 11 ; rgb:RRRR/GGGG/BBBB ST` with **16-bit-per-channel** values, though the
digit count varies by terminal (xterm emits four hex digits per channel, others
two). A parser must scale by the digit count it actually saw rather than assume
`/0xffff` — the example does, which is why it reads both `1e1e` and a
hypothetical `1e` as `0x1E`.

Then the app has to classify the color itself, and that is where the
[threshold problem](../color-derivation/index.md#scheme-inference-vs-the-os-answer)
enters: Rec. 601 luma, Windows' `(5G+2R+B)/8`, and CIE `L*` disagree in a band
around the midpoint. Mode 2031 sidesteps the whole question by returning the
terminal's own answer.

### Running both

[`examples/color-scheme-probe.d`](./examples/color-scheme-probe.d) issues both
queries with a 200 ms budget, parses both replies, and reports whether they
agree. Against a terminal that implements mode 2031 with a dark background:

```[Output]
query  CSI ? 996 n   -> ESC[?997;1n
       color scheme  -> dark

query  OSC 11 ; ? ST -> ESC]11;rgb:1e1e/1e1e/2e2eESC\
       background   -> #1E1E2E (Rec.601 luma 31 ⇒ dark)
       agreement    -> mode 2031 and the luminance guess agree
```

and against one that implements neither:

```[Output]
query  CSI ? 996 n   -> (no reply within 200ms)
       color scheme  -> unknown (mode 2031 unsupported)

query  OSC 11 ; ? ST -> (no reply within 200ms)
       background   -> unavailable (OSC 11 unsupported or blocked)
```

Both captures are real, produced by running the probe under a pty harness that
plays the part of each kind of terminal.

## Hazards

### Timeouts are not optional

A terminal that does not implement a query **says nothing**. There is no error
reply, no NAK, no capability bit to check first. An application that issues a
query and blocks on a read hangs forever on `xterm`, on a pipe, and on a serial
console. The established budget is 100–200 ms: long enough for an ssh round trip,
short enough not to be a visible startup stall.

This is the single most important difference between the terminal and every other
platform in this survey. Everywhere else, "unsupported" is an error code; here it
is silence, and silence has to be a timer.

### Multiplexers

`tmux` does not forward an unrecognized query to the outer terminal and does not
answer it either, so a bare probe times out. The escape hatch is DCS passthrough
— wrap the sequence as `ESC P tmux; <sequence with every ESC doubled> ESC \` —
which the example does automatically when `$TMUX` is set.

There is a second, subtler failure: tmux has historically **cached** the OSC 11
answer, so it "doesn't reflect any change in background color until client is
detached/attached". An app that trusts a cached background under tmux follows a
scheme the user left an hour ago. tmux 3.6's mode 2031 support is the real fix.

### Nested terminals

The question "what is the background" is ill-posed through a stack of terminals.
As one implementer put it, "the final appearance of terminal window is often a
product of many stacked virtual terminals. If the topmost one doesn't set a
background itself (i.e. it is 'transparent'), it can't reasonably guess displayed
colors." Mode 2031's semantic answer degrades better here than OSC 11's literal
one: a pass-through layer can forward a light/dark bit meaningfully, where
forwarding an RGB it does not own is a guess.

### The reply is input

The response arrives on **stdin**, interleaved with whatever the user is typing.
Consequences: the terminal must be in raw mode (canonical mode waits for a
newline that never comes), echo must be off (or the reply is painted into the
user's scrollback), and a full-screen application that already owns the input
stream must route `CSI ? 997` through its own decoder rather than reading stdin
behind its back. For [`sparkles:tui`](../../../specs/tui/), whose event loop owns
stdin, this means mode 2031 replies belong in the
[input decoder](../../../specs/ui/input.md), not in a side-channel read.

### `COLORFGBG`

An old rxvt convention: `"15;0"` means foreground 15, background 0. It is set at
launch, never updated, frequently absent, frequently stale (it survives an `ssh`
into a differently-themed host), and expresses only palette indices. Read it as a
last resort; never prefer it over a live query.

## Reachability

The best of any platform here, and for a pleasing reason: it needs **nothing**.
No D-Bus client, no COM apartment, no JNI, no toolkit — two `write(2)` calls, a
`poll(2)` and a small parser. The example depends on nothing beyond
`sparkles:base` for the tty check.

That makes the terminal the natural **first** backend to implement for Sparkles:
it is the least code, it covers the sink `hue` uses most, and it exercises the
whole abstraction (query, capability-absent, and push notification) end to end.

## Traps

| Trap                                         | Consequence                                                     |
| -------------------------------------------- | --------------------------------------------------------------- |
| Blocking on the reply                        | hangs forever on any terminal that does not implement the query |
| Not entering raw mode                        | the reply never arrives (canonical mode waits for a newline)    |
| Leaving echo on                              | the escape reply is painted into the user's scrollback          |
| Bare query under `tmux`                      | swallowed; needs DCS passthrough                                |
| Trusting a cached OSC 11 answer under `tmux` | follows a scheme the user has already changed                   |
| Assuming a fixed 4-hex-digit OSC 11 reply    | mis-scales terminals that emit two                              |
| Leaving mode 2031 enabled at exit            | the next application on that tty gets unexpected reports        |
| Preferring `COLORFGBG` over a live query     | stale across `ssh`, absent on most terminals                    |

## Strengths

- A genuine semantic answer plus push notification, matching what desktop
  platforms offer — over a pty.
- Zero dependencies; implementable in a hundred lines.
- Works over `ssh`, in a container, and in a serial console, where every
  desktop mechanism in this survey fails.
- Degrades to OSC 11, then to `COLORFGBG`, then to configuration, cleanly.

## Weaknesses

- No accent color and no contrast preference — the terminal simply has neither.
- Capability detection is a timeout, not a query.
- Multiplexers interpose and historically cache.
- Very new: an app must still ship the OSC 11 fallback for years.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                            | Trade-off                                                                  |
| --------------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Report a light/dark _bit_, not the background color | the terminal already knows; the app stops guessing from luminance    | the app still needs OSC 11 to know the actual color to blend against       |
| Split query (`996`) from subscription (`2031`)      | a one-shot tool pays one round trip; a TUI subscribes once           | two mechanisms to implement and two states to unwind at exit               |
| Notification carries no value                       | no stale-value races; one code path for initial read and update      | every change costs an extra round trip                                     |
| Silence for unsupported                             | no negotiation, no capability database, works with 40-year-old terms | every consumer must implement a timeout; there is no "not supported" reply |
| Deliver replies on stdin                            | uses the existing channel; no new fd, no new protocol                | collides with the application's own input decoding                         |

## Sources

- [Color scheme reporting — mode 2031][vtdn2031] — sequences, reply format, implementation list
- [OSC 11][vtdnosc11] — background query and reply format
- [Contour — color palette update notifications][contour] — the originating proposal
- [tmux 3.6 mode 2031 support][tmuxpr] · [tmux OSC 11 caching][tmuxcache]
- [Terminal color detection: `NO_COLOR`, `COLORTERM`, OSC probes][terminfodev]
- ["Thoughts on using OSC codes to automate changing terminal color schemes"][goral] — the nested-terminal argument, quoted above
- Live captures via a pty harness reproducing a mode-2031 terminal and a silent one; see [`examples/color-scheme-probe.d`](./examples/color-scheme-probe.d)

<!-- References -->

[contour]: https://github.com/contour-terminal/contour/blob/0392ef3d0ef52cdb5c0df6f7efe5856e5dc28d3c/docs/vt-extensions/color-palette-update-notifications.md
[goral]: https://goral.net.pl/post/osc-color-scheme-automation/
[terminfodev]: https://terminfo.dev/fundamentals/color-detection
[tmuxcache]: https://github.com/tmux/tmux/issues/3582
[tmuxpr]: https://github.com/tmux/tmux/pull/4353
[vtdn2031]: https://vtdn.dev/docs/decset/mode2031-color-scheme/
[vtdnosc11]: https://vtdn.dev/docs/osc/osc11/
