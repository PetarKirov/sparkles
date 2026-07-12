# Terminal Capability Detection Case Study

A comparative analysis of how terminal programs discover **what the terminal they are
attached to can do** — color depth, keyboard protocols, graphics, synchronized output,
in-band resize — across TUI frameworks, the substrate detection libraries they delegate
to, terminal emulators' own documentation, and the environment-variable conventions
that bind them. The lens is the same as the [Tree-View][tree-view-case-study] and
[Table Row/Column-Span][table-span-case-study] case studies:
[Sean Parent's principles][sean-parent-index] (value semantics, avoiding incidental
data structures, separating algorithms from data) and the project's D guidelines
([Design by Introspection][dbi-guidelines], [functional/declarative
style][functional-guidelines]). The motivating gap is that Sparkles' current
[`detectTermCaps`][term-caps-src] is deliberately **env + ioctl only** — the
[tui-components decision ledger][tui-spec] scopes out "terminal queries (DA1/CPR/kitty
probes need raw-mode response reading; `term_caps` stays env + ioctl until an
interactive component forces it)" — while every primitive a query engine needs (raw
mode with timed reads, a CSI/OSC/DCS scanner, mode emitters) already exists in-tree,
unwired. This survey maps the design space a dedicated capability-detection library
must choose from, and grounds it empirically with a co-located
[query probe][query-probe] run against real terminals ([§16](#16-appendix-empirical-response-matrix)).
It extends the capability sections of the [catalog][tui-index]'s per-library dossiers
(notably [libvaxis][libvaxis-dossier] and [notcurses][notcurses-dossier]) and the
[comparison][comparison]'s no-terminfo recommendation with source-level evidence.

**Last reviewed:** July 12, 2026

## 1. Introduction

Every other problem in a terminal UI library begins with an answer to "what is on the
other end of this file descriptor?" — yet the truth about the attached terminal is not
stored in any one place. It is **distributed across three locations with different
freshness and different failure modes**:

- **The process environment** — `TERM`, `COLORTERM`, `TERM_PROGRAM`, `NO_COLOR`, … —
  cheap, synchronous, and _hearsay_: variables are set by the terminal, the multiplexer,
  the login chain, or leaked from an entirely different terminal, and the most useful
  ones are stripped by `ssh` and `sudo` by default ([§3](#3-the-environment-variable-layer),
  [§12](#12-failure-modes-and-hostile-environments)).
- **An on-disk database** — terminfo, keyed by the terminal's _self-reported name_ —
  authoritative about what some version of the named terminal could do when the entry
  was written, silent about everything invented since, and wrong whenever `$TERM` lies
  ([§4](#4-the-terminfo-layer-and-its-decline)).
- **The terminal itself** — reachable only through a write-then-read protocol
  (device-attribute reports, `DECRQM`, `XTGETTCAP`, OSC color queries), which requires
  raw mode, a timeout policy, and a plan for interleaved user input — but is the only
  source that can never be stale ([§5](#5-runtime-interrogation)).

Every library surveyed here occupies a point in the space defined by four sub-problems:

- **What to trust** — env vars, the database, the terminal's own answers, or a
  hierarchy of all three (and which wins on conflict).
- **When to ask** — a one-shot snapshot at startup, lazily on first use, or an ongoing
  subscription to capability _changes_ (dark/light switches, resizes).
- **How long to wait** — interrogation is asynchronous; a terminal that does not
  understand a query typically **answers nothing**, so every query design needs either
  a fence (a final query everything answers) or a deadline, or both.
- **How to degrade** — what the program does at each capability tier, and whether the
  user can override the verdict in both directions.

The single most important finding of this survey: **the ecosystem is migrating, from
every starting point, toward asking the terminal directly.** libvaxis was born
query-first; tcell v3 removed its terminfo subsystem for a built-in VT model; ink — the
archetypal env-only stack — grew its first escape-sequence probe precisely to avoid
"maintaining a hardcoded whitelist of terminal names"; and bubbletea v2 upgrades its
env-derived color profile at runtime when the terminal reports `RGB`/`Tc` capabilities.
Environment sniffing survives as the fast, non-invasive default; the database survives
as a legacy compatibility layer; but the growth is all in interrogation — and in the
subscription protocols ([§6](#6-negotiation-and-subscription-capabilities)) that turn
"capability detection" from a startup event into a stream.

---

## 2. The five detection layers

Every mechanism surveyed falls into one of five layers, ordered by cost and by how
direct the evidence is. This taxonomy is the spine of the rest of the document.

| #      | Layer                           | What it reads                                                                           | Cost                      | Works piped? | Exemplars                                                                                                                     |
| ------ | ------------------------------- | --------------------------------------------------------------------------------------- | ------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| **L0** | **OS / stream introspection**   | `isatty`, `ioctl(TIOCGWINSZ)`, `GetConsoleMode`, `os.release()`                         | one syscall               | yes          | everything; Sparkles [`term_caps`][term-caps-src]                                                                             |
| **L1** | **Static environment sniffing** | `TERM`, `COLORTERM`, `TERM_PROGRAM`, `NO_COLOR`, `CLICOLOR*`, `FORCE_COLOR`, `CI`       | one `getenv`              | yes (lies)   | [supports-color][supports-color-index], [termenv][tv-unix], Sparkles [`term_caps`][term-caps-src]                             |
| **L2** | **Terminfo / termcap database** | the compiled entry for `$TERM`                                                          | file read + parse         | yes (lies)   | ncurses, [tcell v2][tcell-v2], vty, [notcurses][notcurses] (baseline), [unibilium][unibilium]                                 |
| **L3** | **Runtime interrogation**       | DA1/DA2, `XTVERSION`, `XTGETTCAP`, `DECRQM`, kitty `CSI ?u`, OSC 10/11                  | write + fenced/timed read | no           | [libvaxis][libvaxis], [notcurses][notcurses], [termwiz][termwiz-mod], [textual][textual], crossterm (kbd), termenv (bg color) |
| **L4** | **Negotiation / subscription**  | mode 2048 resize reports, mode 2031 scheme reports, kitty keyboard push/pop, `SIGWINCH` | ongoing event stream      | no           | [libvaxis][libvaxis], kitty protocol clients, Sparkles' `SIGWINCH` handler ([`term_caps`][term-caps-src])                     |

Two cross-cutting observations frame the layers:

**Color is the only capability class L1 can detect — which is why env-only libraries
are color-only libraries.** There is no environment variable for "supports the kitty
keyboard protocol", "honors mode 2026", or "renders sixels"; the conventions that exist
(`COLORTERM`, the `-256color`/`-direct` suffixes, `NO_COLOR`, `FORCE_COLOR`) all encode
color depth or color consent. A library whose detection stops at L1 — supports-color,
termenv's `ColorProfile`, Sparkles today — can classify color and nothing else; every
other capability class requires L2 hearsay, L3 interrogation, or hardcoded terminal
allowlists (the approach ink's own source comments call out as the thing to avoid).

| Capability class                                   | L0  | L1                 | L2                | L3                         | L4                     |
| -------------------------------------------------- | --- | ------------------ | ----------------- | -------------------------- | ---------------------- |
| tty-ness, size                                     | ✓   | —                  | —                 | `CSI 14t`/CPR (rare)       | `SIGWINCH` / mode 2048 |
| color depth                                        | —   | ✓ (the only class) | ✓ (`RGB`, colors) | DA1, `XTGETTCAP RGB/Tc`    | —                      |
| keyboard protocol (kitty `CSI u`)                  | —   | —                  | —                 | `CSI ?u`                   | push/pop flags         |
| graphics (kitty APC, sixel)                        | —   | —                  | —                 | APC `a=q` query, DA1 attrs | —                      |
| DEC modes (2004, 2026, 2027, 2031, 2048)           | —   | —                  | —                 | `DECRQM`                   | set/reset + reports    |
| OSC features (8 links, 52 clipboard, 10/11 colors) | —   | —                  | —                 | OSC `?` queries (10/11/52) | mode 2031 reports      |
| unicode width behavior                             | —   | —                  | —                 | `DECRQM 2027`, probe + CPR | mode 2027 set          |

**Later layers refine, earlier layers veto.** In every mature multi-layer detector the
flow is the same: L0 gates everything (no tty ⇒ no escapes), L1 carries the user's
_consent_ (`NO_COLOR`, `FORCE_COLOR` — which no deeper layer may override) plus a first
capability guess, and L2/L3 refine the guess upward. notcurses runs terminfo → env →
queries; charmbracelet's colorprofile literally computes "the maximum of env, terminfo,
and tmux"; bubbletea v2 starts from env+terminfo and upgrades when `XTGETTCAP` answers
arrive. The layers are not alternatives; they are a pipeline with a veto at the top.

---

## 3. The environment-variable layer

The environment layer splits into two families with opposite data flow: **consent
variables** carry the _user's_ intent down into every program (`NO_COLOR`,
`CLICOLOR`/`CLICOLOR_FORCE`, `FORCE_COLOR`), while **advertisement variables** carry
the _terminal's_ identity and color claim up through the process tree (`COLORTERM`,
`TERM`, `TERM_PROGRAM`). Consent is authoritative — it must never be overridden by any
deeper detection layer. Advertisement is hearsay — it is set once at spawn time,
inherited blindly, stripped by `ssh`/`sudo`, and overwritten by multiplexers.

### Consent: NO_COLOR, CLICOLOR, FORCE_COLOR

**`NO_COLOR`** is the presence-not-value disable switch, proposed in 2017 by Joshua
Stein and now honored across hundreds of tools:

> "Command-line software which adds ANSI color to its output by default should check
> for a `NO_COLOR` environment variable that, when present and not an empty string
> (regardless of its value), prevents the addition of ANSI color."
> — [no-color.org][no-color] ([source][no-color-src])

Two clarifications from its FAQ matter for library design: the standard governs
**color only** ("This standard only signals the user's intention regarding adding ANSI
color to text output" — bold/underline/italic are explicitly out of scope), and it is
"a hint to the software running in the terminal to suppress addition of color, not to
the terminal" — i.e. it belongs in the emit decision, not in capability _classification_.
Sparkles already implements exactly this split: [`classifyColorDepth`][term-color-src]
never sees `NO_COLOR`; [`detectTermCaps`][term-caps-src] folds consent into the final
snapshot.

**`CLICOLOR` / `CLICOLOR_FORCE`** predate `NO_COLOR` (standardized 2015 on
[bixense.com][clicolors] from existing FreeBSD/macOS [`ls(1)`][freebsd-ls] practice,
where `CLICOLOR_FORCE` is documented as overriding the "disabled if the output is not
directed to a terminal" default). The classic semantics the ecosystem implemented:
`CLICOLOR == 0` disables, `CLICOLOR_FORCE != 0` forces color "no matter what" — i.e.
even onto a pipe. Notably, the standard now **deprecates itself**:

> "Note: This standard is deprecated. For new applications, we recommend using the
> force-color and no-color standards instead of this standard. Software that already
> supports this standard should treat FORCE_COLOR as an alias for CLICOLOR_FORCE,
> enabling color whenever either is set, unless NO_COLOR is also set."
> — [bixense CLICOLOR][clicolors]

**`FORCE_COLOR`** (from the Node ecosystem) is a leveled force: "`FORCE_COLOR=1`
(level 1), `FORCE_COLOR=2` (level 2), or `FORCE_COLOR=3` (level 3) to forcefully
enable color, or `FORCE_COLOR=0` to forcefully disable. The use of `FORCE_COLOR`
overrides all other color support checks" — [supports-color][supports-color-readme].
It is the only consent variable that carries a _depth_, not just a boolean.

The precedence question — what happens when disable and force are both present — is
answered differently across the ecosystem, and the differences are load-bearing:

| Detector                                   | `NO_COLOR` semantics                                      | Force variable                      | Disable vs force                                                       |
| ------------------------------------------ | --------------------------------------------------------- | ----------------------------------- | ---------------------------------------------------------------------- |
| [supports-color][supports-color-index]     | not consulted (chalk ecosystem uses `FORCE_COLOR` only)   | `FORCE_COLOR=0..3` (also a _floor_) | `FORCE_COLOR` "overrides all other color support checks"               |
| [termenv][tv-go]                           | any non-empty value disables                              | `CLICOLOR_FORCE`                    | "If NO_COLOR is set … ignoring CLICOLOR/CLICOLOR_FORCE" — disable wins |
| [colorprofile][cp-env]                     | `strconv.ParseBool` — **`NO_COLOR=yes` does NOT disable** | `CLICOLOR_FORCE`                    | "NO_COLOR takes precedence over CLICOLOR/CLICOLOR_FORCE"               |
| Sparkles [`detectTermCaps`][term-caps-src] | any non-empty value disables                              | `CLICOLOR_FORCE`                    | disable beats force ("never overrides an explicit disable")            |
| [bixense standard][clicolors] (current)    | disable wins                                              | `CLICOLOR_FORCE`/`FORCE_COLOR`      | "enabling color whenever either is set, unless NO_COLOR is also set"   |

The colorprofile row is a caution, not a model: parsing `NO_COLOR` with a boolean
parser deviates from the spec's "present and not an empty string (regardless of its
value)" wording, so `NO_COLOR=yes` silently keeps color on. Getting consent parsing
exactly right is table stakes — it is the one part of detection users deliberately set.

### Advertisement: COLORTERM, TERM, TERM_PROGRAM

**`COLORTERM=truecolor`** is the de-facto truecolor advertisement. Its history explains
its existence: terminfo simply had no way to say "24-bit color" until 2018 — "Terminfo
has supported the 24-bit TrueColor capability since ncurses-6.0-20180121, under the
name \"RGB\"" — so the [termstandard/colors][termstandard] effort standardized the
convention the S-Lang library had introduced ("a check that `$COLORTERM` contains
either \"truecolor\" or \"24bit\""). VTE, Konsole, iTerm2 export it, and tmux sets
`COLORTERM=truecolor` into every pane's environment ([environ.c][tmux-environ]). The
same document is frank about the weakness:

> "Having an extra environment variable (separate from `TERM`) is not ideal: by default
> it is not forwarded via sudo, ssh, etc, and so it may still be unreliable even where
> support is available in programs." — [termstandard/colors][termstandard]

**`TERM`** carries capability information only through naming conventions — a root
name plus "any reasonable number of hyphen-separated feature suffixes"
([term(7)][term7]). Two suffixes are load-bearing for detectors: `-256color`
(introduced with xterm patch #111; in the terminfo database since 1999 —
[ncurses FAQ][ncurses-faq]) and `-direct` (direct-color entries from
[ncurses 6.1][ncurses-61] / xterm patch #331, 2018). `TERM=dumb` is the
conventional "no capabilities" floor (database entry: `dumb|80-column dumb tty`).
Detectors regex these conventions — supports-color grants level 2 for
`/-256(color)?$/i` and level 1 for `/^screen|^xterm|^vt100|^vt220|^rxvt|color|ansi|cygwin|linux/i`;
Sparkles' [`classifyColorDepth`][term-color-src] checks `"direct"` and `"256color"`
substrings — which works precisely as well as terminal authors keep naming discipline.

**`TERM_PROGRAM` / `TERM_PROGRAM_VERSION`** began as an Apple Terminal.app convention
(`TERM_PROGRAM=Apple_Terminal`) and spread: iTerm2 (`iTerm.app`), VS Code (`vscode`),
WezTerm, ghostty, and tmux — which has exported "`TERM_PROGRAM` and
`TERM_PROGRAM_VERSION` like various other terminals" since 3.2, meaning inside tmux the
variable identifies **the multiplexer, not the terminal**. Alacritty refuses to set it
on principle, and its maintainer's rationale is the whole layer's critique in one line:

> "You shouldn't need to uniquely identify your terminal. … Terminal capabilities
> should be queried using terminfo." — [alacritty#4793][alacritty-4793]

And like `COLORTERM`, it evaporates at the ssh boundary: sshd's `AcceptEnv` default "is
not to accept any environment variables" ([sshd_config][sshd-config]) — which is why
ghostty's ssh integration explicitly requests `SendEnv` forwarding of `COLORTERM`,
`TERM_PROGRAM`, and `TERM_PROGRAM_VERSION` ([§12](#12-failure-modes-and-hostile-environments)).

### CI environments

CI logs are the one place programs _want_ to emit color at a non-tty, so detectors
special-case it. The convention is `CI=true` plus a provider variable
(`GITHUB_ACTIONS`, `GITLAB_CI`, …). supports-color grants GitHub Actions, Gitea
Actions, and CircleCI truecolor and the older providers 16-color — a hardcoded,
per-provider capability table that must be maintained by hand; Azure DevOps
(`TF_BUILD`) is even checked _before_ the tty test. termenv goes the other way: a set
`CI` variable forces its tty check to fail, treating CI as a non-terminal and leaving
forcing to `CLICOLOR_FORCE`. The two postures — "CI is a colorful non-tty" vs "CI is
not a terminal" — are both defensible; what matters for a library is that the decision
is explicit and overridable.

---

## 4. The terminfo layer and its decline

### The database and its API

terminfo is "a database describing terminals … by giving a set of capabilities which
they have" ([terminfo(5)][terminfo5]), compiled by [`tic`][tic1] into per-type entries
(canonically under `/usr/share/terminfo`, with `$TERMINFO` and `$HOME/.terminfo`
overrides as ncurses extensions) and keyed by `$TERM`. The compiled format is itself a
fossil of a performance fight: Mark Horton, who announced terminfo at USENIX Summer
1982 as the successor to Bill Joy's termcap, moved to compilation because "the termcap
algorithm for reading the entry into a set of capabilities is QUADRATIC on the size of
the entry … taking 1/4 second of CPU time on a VAX 750" ([tctest][tctest]).

The classic API is aggressively process-global: `setupterm` "stores its information
about the terminal in a `TERMINAL` structure pointed to by the global variable
`cur_term`" ([curs_terminfo(3x)][curs_terminfo]), and switching terminals means calling
`set_curterm` to swap the global. Every value read through the classic interface is a
read of ambient mutable state — the antithesis of a capability _value_
([§14](#14-analysis-through-sean-parents-principles)). The modern refactoring of this
layer is [unibilium][unibilium-readme] — "a very basic terminfo library … It doesn't
depend on curses or any other library. It also doesn't use global variables, so it
should be thread-safe" — which is how Neovim reads terminfo. Note what unibilium is:
a _parser_. It reads files; it never talks to a terminal.

### The frozen table and the extension escape hatch

The standard capability table froze with System V ("the version of curses/terminfo in
System V Release 2 was frozen in April 1983" — Horton, via [tctest][tctest]), so every
modern capability lives in the **user-defined extension space** that ncurses 5.0 added
via `tic -x` / `infocmp -x` ([user_caps(5)][user_caps5]). Truecolor is the canonical
example: the `RGB` extension capability arrived in 2018 with ncurses 6.1's `-direct`
entries; before that, the ecosystem invented `Tc` (tmux) — and consumers must know to
ask for both. kitty advertises styled underlines the same way ("query the terminfo
database for the `Su` boolean capability" — [kitty underlines][kitty-underlines]).
The escape hatch works, but capability knowledge now lives in vendor conventions
layered over a frozen standard, and users end up patching the database's gaps by hand —
tmux's own FAQ tells users to assert their outer terminal's truecolor with
`set -as terminal-features ",gnome*:RGB"` ([tmux FAQ][tmux-faq]) because the platform
entry doesn't say so.

### The critique cluster

Four independent, current primary sources converge on the same verdict from different
directions:

**ghostty: the database fails exactly when you need it.** A new terminal that ships its
own entry (`xterm-ghostty`) meets reality the first time a user runs ssh: "If you use
SSH to connect to other machines that do not have Ghostty's terminfo entry, you will
see error messages like `missing or unsuitable terminal: xterm-ghostty`"
([ghostty terminfo help][ghostty-terminfo]). The documented workarounds are to copy the
entry to every remote host (`infocmp -x xterm-ghostty | ssh YOUR-SERVER -- tic -x -`)
or to configure ssh to _lie_ (`SetEnv TERM=xterm-256color`) — and ghostty ships a
whole `ghostty +ssh` automation layer ([ssh feature][ghostty-ssh]) to do both. A
capability system whose deployment story is "install our row into every database you
will ever touch, or else advertise a false identity" has failed as a protocol.

**Applications route around the database.** Mitchell Hashimoto's ghostty devlog
documents the endgame:

> "a lot of naughty programs do string matching on TERM to determine if a terminal
> supports some set of functionality. This is wrong and very naughty, do not do this!
> The correct approach is to query the terminfo database." … "Vim 9.0 supports Kitty
> Keyboard Protocol, but hardcodes the list of terminals that support it and doesn't
> properly respect the terminfo database." — [ghostty devlog 004][devlog004]

When even flagship applications treat `$TERM` as a brand name to string-match rather
than a database key, the emulator's _name_ — not its entry — becomes the compatibility
surface, and every new terminal must masquerade as an old one (`xterm-` prefixes
everywhere) to function.

**libvaxis: skip the database entirely.** "Libvaxis _does not use terminfo_. Support
for vt features is detected through terminal queries" ([libvaxis README][libvaxis]) —
the design stance Sparkles' own [`term_control`][term-control-src] module header
already cites as the modern consensus.

**tcell v3: remove the database after a decade of using it.** The most structurally
significant data point, because tcell v2 owns one of the most complete Go terminfo
implementations — and v3 deletes it:

> "The Terminfo subsystem has been removed entirely. Essentially the old terminfo based
> design has long proved to be inferior for modern terminal applications, and has not
> kept up with newer terminal features such as 24-bit color, different mouse reporting
> modes, bracketed paste, advanced text styling, and so forth. … It turns out that
> pretty much all of the terminal logic can be consolidated to just a few classes of
> terminals with substantial overlap." — [tcell CHANGESv3.md][tcell-changesv3]

with `$TERM` demoted to a hint: "we still examine `$TERM` when appropriate, but if the
value is not one we recognize, then we will assume something reasonably capable and
compatible at some level with _xterm_ or at least ECMA-48."

### What the database fundamentally cannot express

Beyond staleness, two structural limits remain even with a perfectly maintained
database. First, terminfo describes a terminal _type_, not the terminal actually
attached — once `$TERM` lies (ghostty's own documented ssh fallback institutionalizes
the lie), every capability read is a guess about the wrong subject. Second, terminfo is
static: it can assert that a terminal _understands_ mode 2026, but never whether that
mode is _currently set_, whether the multiplexer in between passes it through, or what
the background color is right now — runtime state is only knowable by asking
([§5](#5-runtime-interrogation)).

---

## 5. Runtime interrogation

Interrogation inverts the trust model of L1/L2: instead of believing what the
environment _says about_ the terminal, the program asks the terminal _about itself_.
The mechanics are uniform across every implementation surveyed — write queries, read
replies under raw mode — and every design decision follows from one asymmetry: **a
terminal that supports a query answers it; a terminal that doesn't usually answers
nothing.** Detection by silence requires a protocol for knowing when to stop waiting.

### The query catalog

| Query              | Sequence               | Reply shape                             | What it proves                                                                    |
| ------------------ | ---------------------- | --------------------------------------- | --------------------------------------------------------------------------------- |
| Primary DA (DA1)   | `CSI c`                | `CSI ? Ps ; … c`                        | terminal exists and answers; attribute list carries caps (4 = sixel, 28 = DECERA) |
| Secondary DA (DA2) | `CSI > c`              | `CSI > Pp ; Pv ; Pc c`                  | identity + version (tmux answers `84` = `T`, screen `83` = `S`, kitty `1;4000`)   |
| Tertiary DA (DA3)  | `CSI = c`              | `DCS ! \| hex ST`                       | identity by four-byte code (`464F4F54` = "FOOT", `7E565445` = "~VTE")             |
| XTVERSION          | `CSI > 0 q`            | `DCS > \| name version ST`              | exact name + version string (`ghostty 1.3.1`, `tmux 3.6a`)                        |
| XTGETTCAP          | `DCS + q hex… ST`      | `DCS 1 + r key=val ST` / `DCS 0 + r ST` | terminfo-style caps (`RGB`, `Tc`, `Su`) from the terminal, not the database       |
| DECRQM             | `CSI ? Pn $ p`         | `CSI ? Pn ; Ps $ y`                     | mode recognized/set/reset — the only way to learn _runtime_ mode state            |
| kitty keyboard     | `CSI ? u`              | `CSI ? flags u`                         | protocol support + current enhancement flags                                      |
| kitty graphics     | `APC G i=…,a=q ; … ST` | `APC G i=… ; OK ST`                     | graphics protocol round-trip actually works                                       |
| OSC 10 / 11        | `OSC 10 ; ? BEL`       | `OSC 10 ; rgb:RRRR/GGGG/BBBB BEL-or-ST` | actual fg/bg colors → dark/light detection                                        |
| CPR (DSR 6)        | `CSI 6 n`              | `CSI row ; col R`                       | cursor position — a movement oracle, and a universal fence                        |
| XTWINOPS 14/16/18  | `CSI 14 t` …           | `CSI 4 ; h ; w t` …                     | pixel/cell geometry (needed for images)                                           |

The replies are self-describing — each shape is distinguishable by its introducer,
prefix, and final byte — which is why every implementation routes them through its
ordinary input parser rather than a dedicated response channel, and why capability
replies race with keystrokes ([§12](#12-failure-modes-and-hostile-environments)).

### The fence pattern

Since unsupported queries produce silence, the standard move is to **batch every query
in one write and end with a query that everything answers**; when the final reply
arrives, everything unanswered never will be. Primary DA is the canonical fence — it
predates the VT100's successors and, as notcurses puts it, "All known terminals respond
to DA1" ([termdesc.c][nc-termdesc]). The pattern recurs independently across the
survey:

- **libvaxis** ends its battery with `CSI c` and blocks on a futex: "This call will
  block until Vaxis.query_futex is woken up, or the timeout. Event loops can wake up
  this futex when cap_da1 is received" ([Vaxis.zig][vaxis-src]).
- **notcurses** sends "any queries we have … with a trailing Device Attributes. all
  known terminals will reply to a Device Attributes, allowing us to get a negative
  response if our queries aren't supported" ([termdesc.c][nc-termdesc]).
- **lipgloss v2** fences its OSC 11 background query with DA1 and stops reading at the
  `CSI ? … c` reply ([terminal.go][lg2-terminal]); **crossterm** does the same for its
  kitty-keyboard query ([§10](#10-hybrid-detectors-crossterm-textual)).
- **termenv** uses the other universal reply as its fence — CPR: "first, send OSC
  query, which is ignored by terminal which do not support it … then, query cursor
  position, should be supported by all terminals" ([termenv_unix.go][tv-unix]).
- **termwiz** fences XTVERSION (a DCS reply) with DA1 and terminates its read loop on
  the first non-DCS action ([probed.rs][termwiz-probed]).

The fence converts an unbounded wait into a bounded one — but only if the fence itself
is answered. The two failure postures frame the design space. notcurses has **no
timeout at all**: its response wait is a bare condition-variable loop, and its own
documentation states the consequence in bold — "if a terminal does _not_ reply in a
recognizable way to Primary Device Attributes, `notcurses_init()` will hang"
([TERMINALS.md][nc-terminals]; its support matrix lists ETerm as exactly this failure).
Textual has **no fence at all**: its two `DECRQM` queries are fire-and-forget, replies
are parsed as ordinary input whenever they arrive, and capabilities simply default to
off ([§10](#10-hybrid-detectors-crossterm-textual)). Everything else picks a deadline
in between: 200 ms (ink's kitty probe), 1 second (vaxis convention, this repo's
[query probe][query-probe]), 2 seconds (lipgloss v2), 5 seconds (termenv) — and the
[empirical matrix](#16-appendix-empirical-response-matrix) shows real terminals
answering a 15-query battery in ~1–20 ms, so the deadline is pure insurance against
the no-emulator case (a bare PTY, a serial line, an unanswering multiplexer).

### Mechanics: raw mode, bleed, and interleaving

Reading replies requires raw mode — replies arrive on stdin, and with `ICANON`/`ECHO`
active they would sit in the line buffer and echo to the screen. Beyond that baseline,
the surveyed implementations encode four hard-won lessons:

- **Own the right file descriptor.** libvaxis opens `/dev/tty` read-write rather than
  trusting stdin/stdout ([tty.zig][vaxis-tty]); termenv refuses to query from a
  background process at all ("if in background, we can't control the terminal" —
  [termenv_unix.go][tv-unix]), because a backgrounded reader racing the foreground job
  for terminal input corrupts both.
- **Guard against bleed.** A terminal that half-understands a sequence prints the
  remainder. notcurses sends CPR _first_ "because terminals which don't consume the
  entire escape sequences following will bleed the excess into the terminal, and we
  want to blow any such output away" ([termdesc.c][nc-termdesc]); it skips the kitty
  APC query on Windows ("bled through ConHost") and OSC 4 on the Linux console
  ("bleeds it"); Textual skips `DECRQM` entirely under `TERM_PROGRAM=Apple_Terminal`
  because macOS Terminal "writes a single 'p' into the terminal"
  ([linux_driver.py][textual-linux-driver]). Query _emission_ itself needs an
  allowlist-or-risk decision per sequence family.
- **Expect interleaving.** Replies share the input stream with the user's typing.
  libvaxis's cursor-movement probes produce replies that "when parsed as a Key" are
  literally "a shift + F3", so it gates key dispatch on a `queries_done` flag
  ([Vaxis.zig][vaxis-src]); this repo's probe simply ignores text tokens and counts
  unrecognized escapes. A library must decide whether query replies are events, keys,
  or neither — before the first real keystroke arrives.
- **Expect reordering through intermediaries.** termwiz wraps queries destined for the
  outer terminal in tmux passthrough envelopes and then sleeps 100 ms because "tmux and
  conpty will both re-order the response to dev_attributes before sending the response
  for the passthru … The delay is potentially imperfect for things like a laggy ssh
  connection" ([probed.rs][termwiz-probed]) — ordered-response assumptions hold per
  terminal, not per path.

One more hazard is structural: queries sent by a program that exits before the replies
arrive leak those replies into the parent shell as garbage input (reported repeatedly
against query-at-startup tools, e.g. [superset#4041][superset-4041]). A capability
library owns not just sending queries but _draining_ them — this repo's probe keeps a
post-fence quiet-drain window for exactly this reason.

---

---

## 6. Negotiation and subscription capabilities

The newest capability class breaks the snapshot model entirely: these are not facts to
detect once but **streams to subscribe to**, and their specifications fold detection,
activation, and delivery into single protocol moves.

**Mode 2048 (in-band resize): enabling is the query.** The spec's detection story is a
`DECRQM` like any mode ("A `Ps` value of 0 or 4 means the mode is not supported" —
[in-band-resize spec][mode-2048]), but its activation clause makes even that optional:
"When first enabled, the terminal MUST send a report of the current size." Set the mode
and either a `CSI 48 ; height ; width ; height_pix ; width_pix t` report arrives —
support confirmed, current size delivered, subscription active, all in one round trip —
or nothing does. libvaxis exploits exactly this: 2048 is the one capability in its
battery that is _set_, never queried, and the first arriving report both proves support
and switches off the `SIGWINCH` handler at runtime ("We will be receiving winsize
updates in-band" — [Loop.zig][vaxis-loop]). Textual does query it first, then
auto-enables on a positive reply and likewise stops trusting `SIGWINCH`. The legacy
channel being replaced is instructive: `SIGWINCH` is an out-of-band process signal —
racy against the byte stream, per-process rather than per-screen, and delivered in
signal context (Sparkles' own handler in [`term_caps.d`][term-caps-src] must be
`nothrow @nogc` for exactly that reason). In-band resize turns "terminal size" from an
L0 ioctl plus a signal into an L4 event stream on the same channel as every other
reply.

**Mode 2031 (color-scheme updates): subscription with a one-shot sibling.** Contour's
extension pairs a subscription mode with a DSR query: setting `CSI ? 2031 h` opts into
"unsolicited DSR … messages for color palette updates" (`CSI ? 997 ; 1 n` for dark,
`; 2 n` for light), while `CSI ? 996 n` asks once for the current preference
([color-palette-update-notifications][mode-2031]). vaxis models the two-step shape
faithfully: `DECRQM 2031` in the startup battery detects the capability, and a separate
`subscribeToColorSchemeUpdates` sends the one-shot query plus the mode-set — "The
initial scheme will be reported when subscribing" ([Vaxis.zig][vaxis-src]). The
adoption list (ghostty, kitty, VTE, tmux, Neovim, Zellij …) makes this the most
widely deployed of the new modes — and dark/light is precisely the capability the
env-first stacks spend the most effort approximating with OSC 11 queries
([§8](#8-env-first-substrates-supports-color-termenv-colorprofile)).

**Kitty keyboard flags: negotiation with scoped state.** The keyboard protocol's
enhancement flags are not a boolean capability but a **stack**: `CSI > flags u` pushes,
`CSI < u` pops, and the terminal keeps _per-screen_ stacks so an application that
crashes without popping, or a subprocess that pushes its own flags, degrades sanely
([kitty keyboard protocol][kitty-kbd]). broot demonstrates why the stack matters in
practice: it pops its flags before launching a child terminal program and re-pushes
after ([§10](#10-hybrid-detectors-crossterm-textual)). This is capability state as a
negotiated, nestable session property — closer to a protocol handshake than to a
lookup.

The design consequence is structural: a capability library whose output is a
one-time struct cannot represent this class at all. Size changes, scheme changes, and
flag-stack state arrive as _events after detection completes_; the detection seam
therefore needs an event side — a way for arriving reports to update the capability
value and notify the application — alongside the snapshot. vaxis's architecture
(capability events flowing through the same loop as input, flipping `vx.caps` fields)
and bubbletea v2's message model (`ColorProfileMsg`, `BackgroundColorMsg` delivered
like any other message) are the two worked examples.

---

---

## 7. Query-first stacks: libvaxis, notcurses, termwiz

Three libraries put interrogation at the center of their capability model — and they
make three different bets on what surrounds it: nothing (vaxis), everything
(notcurses), or the application's own judgment (termwiz).

### libvaxis: interrogation as the only source

libvaxis's whole capability model is one value — a struct of default-false booleans
plus a width-method enum (`kitty_keyboard`, `kitty_graphics`, `rgb`, `sgr_pixels`,
`color_scheme_updates`, `explicit_width`, `scaled_text`, `multi_cursor`, and
`unicode: gwidth.Method = .wcwidth`) — filled in exclusively by query replies
([Vaxis.zig][vaxis-src]). `queryTerminal` writes the battery as one concatenated
string — `DECRQM` for modes 1016/2027/2031, a blind `CSI ?2048h` (in-band resize is
_enabled_, never queried — arriving reports are the detection,
[§6](#6-negotiation-and-subscription-capabilities)), two cursor-movement probes,
XTVERSION, kitty `CSI ?u`, the kitty graphics APC query, and the DA1 fence — then
blocks on a futex the event loop wakes when the DA1 reply arrives, with a
caller-supplied timeout (1 second by convention; examples range from 250 ms to 20 s)
([Vaxis.zig][vaxis-src], [ctlseqs.zig][vaxis-ctlseqs]).

The cursor probes are the cleverest detection in the survey: to learn whether the
terminal honors kitty's text-sizing protocol, vaxis homes the cursor, writes an OSC 66
explicit-width cell, and asks _where the cursor ended up_ (`CSI 6n`) — "The returned
response will be something like `\x1b[1;2R` … which when parsed as a Key is a shift +
F3 (the row is ignored). We only care if the column has moved from 1->2"
([Vaxis.zig][vaxis-src]). Capability detection by observable side effect rather than
self-report — the same oracle this repo's ghostty width research used, and immune to
terminals that misdescribe themselves.

Reading the source against the README's reputation also corrects the record in ways
only source reading can: at the current commit, `XTGETTCAP` is an unsent TODO, the
`COLORTERM` shortcut for `rgb` is commented out — leaving `caps.rgb` with **no producer
at all** — and the XTVERSION reply is skipped as an unparsed DCS string. Detection
results gate behavior in a narrow, explicit funnel (`enableDetectedFeatures`): push
kitty keyboard flags if detected, set mode 2027 "only … if we don't have explicit
width", pick pixel-vs-SGR mouse mode — with env overrides applied first
(`VHS_RECORD`, `TERMUX_VERSION`, `TERM_PROGRAM=vscode` force legacy rendering;
`VAXIS_FORCE_WCWIDTH`/`VAXIS_FORCE_UNICODE` pin the width method), and on Windows no
detection at all: "No feature detection on windows. We just hard enable some knowns
for ConPTY" ([Vaxis.zig][vaxis-src]).

### notcurses: every layer at once, fenced but unbounded

notcurses runs the full pipeline — and documents every scar. Its `tinfo` header states
the hybrid up front: capabilities are "acquired from terminfo(5) … some are determined
via heuristics based off terminal interrogation or the TERM environment variable. some
are determined via ioctl(2)" ([termdesc.h][nc-termdesc-h]). The startup order is
tuned: early env matches first (`TERM_PROGRAM=Apple_Terminal`, `rxvt*`, a Linux-console
ioctl), then the query barrage is fired _before_ ncurses `setupterm()` — "we fire it
off early because we have a full round trip before getting the reply, which is likely
to pace init" — then terminfo lookups run while the answers travel
([termdesc.c][nc-termdesc]).

The barrage itself is the maximal form of [§5](#5-runtime-interrogation)'s pattern:
CPR first as a bleed guard ("terminals which don't consume the entire escape sequences
following will bleed the excess … we want to blow any such output away"), then
identification (DA3 "necessary to identify VTE", XTVERSION, XTGETTCAP for
`TN`/`RGB`/`hpa`, DA2 "necessary to get Alacritty's version … we ask it last"), up to
256 OSC 4 palette queries, the feature directives (OSC 10/11 — sent early because GNU
screen "passes this on to the underlying terminal rather than answering itself" —
kitty keyboard, `DECRQM` 2026/1016, XTSMGRAPHICS, the kitty graphics probe, geometry),
and DA1 last ([termdesc.c][nc-termdesc]). But the wait for that fence is a bare
condition variable with **no timeout**, and the consequence is documented in bold:
"if a terminal does _not_ reply in a recognizable way to Primary Device Attributes,
`notcurses_init()` will hang" ([TERMINALS.md][nc-terminals]).

What answers _do_ arrive feed an identification machine — XTVERSION prefixes, DA3 hex
names (`464F4F54` = "FOOT"), DA2 version extraction — whose output keys
`apply_term_heuristics`, a twenty-terminal quirk table introduced with an epigraph
from Dante (Virgil's words at the gates of Hell) and the most honest paragraph in the
field:

> "in a more perfect world, this function would not exist, but this is a regrettably
> imperfect world, and thus all manner of things are not maintained in terminfo … so we
> override and/or supply various properties based on terminal identification performed
> earlier. we still get most things from terminfo, though, so it's something of a
> worst-of-all-worlds deal where TERM still needs be correct, even though we identify
> the terminal. le sigh." — [notcurses `termdesc.c`][nc-termdesc]

The quirks are exactly the residue interrogation cannot reach: Alacritty "implements
DCS ASU, but no detection for it" (applied blind on identification); GNU screen's RGB
is revoked below version 5.0; Terminal.app is detected purely by environment because
it "can't handle even the most basic of queries, instead bleeding them through to
stdout"; tmux earns only `// FIXME what, oh what to do with tmux?`. The aspiration is
stated one comment above the XTGETTCAP macro: "ideally we'd abandon terminfo entirely
(terminfo is great; TERM sucks), and get all properties through terminal queries"
([termdesc.c][nc-termdesc]). And the whole apparatus ships with an inspector —
`notcurses-info`, which "prints all the information it knows about the current
terminal environment" ([notcurses-info(1)][nc-info]) — the pattern this repo's
[query probe][query-probe] follows.

### termwiz: hints over heuristics

termwiz's `caps/mod.rs` opens with the survey's best statement of the problem — the
terminal is local and current, the application remote and stale, the databases suffer
"splay and freshness issues", a multiplexer "hides or perturbs the true capabilities
of the terminal", and per-user terminfo overrides demand "a `$HOME/.terminfo`
directory that is NFS mountable" — before concluding: "It's a bit of a mess."
([caps/mod.rs][termwiz-mod]). Its answer is a three-tier value: `ProbeHints`
(explicit, application-supplied overrides — the name for "the embedder knows better"),
computed over env heuristics — "`new_from_env` … implements some heuristics (a fancy
word for guessing)" — over a loaded terminfo database. Every capability is
`hint.unwrap_or_else(env-or-terminfo fallback)`, so an explicit hint always wins;
`NO_COLOR` forces `MonoChrome`; sixel defaults to false because "I don't know of a way
to detect SIXEL support"; hyperlinks default to true because OSC 8 is "mostly
harmless" on non-supporting terminals — a per-capability _risk posture_, not a single
policy ([caps/mod.rs][termwiz-mod]).

Its runtime probing (`probed.rs`) is deliberately separate and opt-in: XTVERSION
fenced by DA1 plus pixel/cell geometry, with tmux passthrough envelopes and a version
quirk table for tmux releases that swap rows and columns — and its results are
returned to the caller rather than folded back into `Capabilities`
([probed.rs][termwiz-probed]). Meanwhile WezTerm-the-terminal closes the loop from the
other side: it exports `TERM_PROGRAM=WezTerm` (which termwiz's own iTerm2-image logic
recognizes), ships an extended terminfo entry users install with `tic -x`, and answers
XTVERSION and XTGETTCAP `TN`/`Co`/`RGB` — a single project maintaining both halves of
the advertisement/detection contract ([config.rs][wezterm-config],
[terminalstate][wezterm-termstate]).

---

---

## 8. Env-first substrates: supports-color, termenv, colorprofile

The most widely deployed detectors in the world are environment-only — and their
source, read closely, documents both why that model is attractive and where it runs
out of road.

### supports-color and chalk: a pure function of the process

[supports-color][supports-color-index] (the detector under chalk, and therefore under
most colored CLI output in the Node ecosystem) is a single ~200-line file whose only
inputs are env vars, argv, `isTTY`, and `os.release()`. Its cascade, in order:
`FORCE_COLOR` (which "overrides all other color support checks" and acts as a _floor_
for later steps — `const min = forceColor || 0`); `--color` argv flags; Azure DevOps
(`TF_BUILD`, deliberately "above the `!streamIsTTY` check"); the tty gate; `TERM=dumb`
→ floor; Windows version sniffing ("Windows 10 build 10586 is the first Windows release
that supports 256 colors … build 14931 is the first release that supports
16m/TrueColor"); the CI provider table; `COLORTERM === 'truecolor'` → level 3;
hardcoded `TERM` names (`xterm-kitty`, `xterm-ghostty`, `wezterm` → truecolor);
`TERM_PROGRAM` version sniffing (`iTerm.app` ≥ 3 → truecolor, `Apple_Terminal` → 256);
the two `TERM` regexes; any other non-empty `COLORTERM` → 16-color; else 0.

The output is the de-facto **level model** the JS ecosystem shares: 0 = disabled,
1 = 16 colors (`hasBasic`), 2 = 256 (`has256`), 3 = truecolor (`has16m`) — a monotone
degradation ladder rather than independent booleans, computed **per stream** (`stdout`
and `stderr` get separate verdicts via `tty.isatty(1)` / `tty.isatty(2)`). chalk
snapshots the stdout level once at import (`object.level = options.level === undefined
? colorLevel : options.level`) and uses it to downsample rgb/hex requests through
`levelMapping = ['ansi', 'ansi', 'ansi256', 'ansi16m']` ([chalk source][chalk-index]).

What supports-color does _not_ do is equally instructive: no terminfo, no queries —
its only terminal interaction is `isatty`. The cost is visible in the source: a
hand-maintained whitelist of terminal names, a hand-maintained table of CI providers,
and a Windows build-number oracle — capability knowledge frozen into a dependency that
must be re-released whenever the world changes.

### ink: inheritance, CI-first, and one telling exception

[ink][ink-ink-tsx] adds no color detection of its own — `<Text color=…>` funnels
through chalk ([`colorize.ts`][ink-colorize]), so ink's color depth _is_ chalk's
import-time snapshot. Its own capability logic is L0: "Determines if TTY is supported
on the provided stdin" (`isRawModeSupported = stdin.isTTY`), and an interactivity gate
where "CI detection takes precedence: even a TTY stdout in CI defaults to
non-interactive" (via [is-in-ci][is-in-ci]) — non-interactive ink disables all escape
sequences and writes "only the final frame at unmount".

The exception proves the survey's thesis. ink 7 contains exactly one escape-sequence
probe — opt-in kitty keyboard detection — and its comment reads like a conversion
narrative:

> "Auto mode: query the terminal for kitty keyboard protocol support. The CSI ? u query
> is safe to send to any terminal — unsupporting terminals simply won't respond, and
> the 200ms timeout handles that. This avoids maintaining a hardcoded whitelist of
> terminal names." — [ink `src/ink.tsx`][ink-ink-tsx]

Even the ecosystem most committed to env-only detection reaches for interrogation the
moment a capability class has no environment variable — because the alternative is the
whitelist treadmill its own source disavows.

### termenv: env-first with one fenced query

[termenv][tv-unix] (the detector under lipgloss/bubbletea v1;
[catalog dossier][bubbletea-dossier]) runs a pure env cascade —
`GOOGLE_CLOUD_SHELL`; `COLORTERM` truecolor (capped at ANSI256 under GNU screen, with
the comment "tmux supports TrueColor, screen only ANSI256"); an exact-`TERM` truecolor
allowlist (`alacritty`, `contour`, `rio`, `wezterm`, `xterm-ghostty`, `xterm-kitty`);
substring fallbacks — with consent handled separately and correctly: "If NO_COLOR is
set, this will return true, ignoring CLICOLOR/CLICOLOR_FORCE" ([termenv.go][tv-go]).

But termenv also owns the ecosystem's most instructive _single_ query: dark/light
background detection. `BackgroundColor()` sends OSC 11 `?` — and because a
non-supporting terminal answers nothing, it fences the query with a cursor-position
report: "first, send OSC query, which is ignored by terminal which do not support it …
then, query cursor position, should be supported by all terminals"
([termenv_unix.go][tv-unix]). The read loop understands exactly two response shapes
(OSC reply, CPR reply), runs under a hand-rolled raw mode (`ECHO`/`ICANON` cleared via
ioctl), refuses to query at all from background processes and under multiplexers
("screen/tmux can't support OSC, because they can be connected to multiple terminals
concurrently"), and backstops everything with a 5-second `select` timeout. Every
element of the fence pattern ([§5](#5-runtime-interrogation)) is present in miniature —
including the failure mode: bubbletea v1 ships a file-scope `init` workaround whose
comment admits that "Programs that use Lip Gloss/Termenv might hang while waiting for
a [termenv.OSCTimeout] while querying the terminal" if the query races the event
loop's ownership of the tty ([bubbletea v1 `tea_init.go`][bt1-init]).

### colorprofile and the charm v2 stack: env, database, and runtime upgrades

[charmbracelet/colorprofile][cp-env] — the successor detector for lipgloss/bubbletea
v2 — is the layered pipeline in one line of source: "Color profile is the maximum of
env, terminfo, and tmux" (`return max(envp, max(tip, tmuxp))`), where the terminfo leg
checks the `Tc`/`RGB` extension capabilities and the tmux leg literally runs
`tmux info` as a subprocess and scans for truecolor flags. Its API is
detection-as-a-function — `Detect(output io.Writer, env []string)` takes the
environment as a _parameter_ (a testability seam termenv also has via its `Environ`
interface), and its profile enum adds `NoTTY` below `Ascii`, making "not a terminal"
a first-class rung of the ladder rather than a boolean off to the side.

bubbletea v2 then closes the loop with L3: the program detects a profile at startup
(`colorprofile.Detect`), lets the app override it (`WithColorProfile`), makes
background-color querying **opt-in** (`RequestBackgroundColor()` → a
`BackgroundColorMsg` with `IsDark()`), and — most tellingly — **upgrades the profile at
runtime** when terminfo-capability query replies arrive: "To upgrade the terminal color
profile, use the `tea.RequestCapability` command to request the `RGB` and `Tc` terminfo
capabilities" ([bubbletea v2][bt2-tea]). lipgloss v2's standalone query helper is where
the DA1 fence appears in this stack — it sends OSC 11 + DA1 and stops reading at the
DA1 reply, under a 2-second timeout ([lipgloss v2 `terminal.go`][lg2-terminal]). The
v1 → v2 arc — from import-time global detection with a documented hang workaround, to
explicit startup detection, opt-in queries, and runtime capability upgrade messages —
is the single clearest evolution narrative in the survey.

---

## 9. Terminfo substrates: tcell, vty, notty

The database-first libraries are best read as a sequence: tcell built the most complete
terminfo implementation in the TUI world and then abandoned it; vty still runs the
classic model faithfully; notty shows what remains when a library refuses the whole
question.

### tcell: the terminfo maximalist that converted

tcell v2 solved terminfo's deployment problem by **compiling the database into the
binary**: a generator turns 29 curated terminal models into Go packages, a base set
(ansi, tmux, vt100/102/220, xterm) is always linked, an extended 27-entry set comes in
by default, and only as a last resort does `terminfo/dynamic` shell out to `infocmp`
at runtime ([tcell v2 `terminfo/`][tcell-v2]). But even at v2 the database was already
a façade over heuristics. `LookupTerminfo` _fabricates_ entries — synthesizing
`-truecolor` variants when `COLORTERM=truecolor` — and `tscreen.go` layers every
modern capability over the database on inference, in so many words: "Another
workaround for lack of reporting in terminfo. We assume if the terminal has a mouse
entry, that it offers bracketed paste", and mouse handling itself relies "on the fact
that pretty much _every_ terminal that supports mouse tracking follows the XTerm
standards" ([tcell v2 `tscreen.go`][tcell-tscreen]). v2 sends zero queries; its
capability model is a database plus a folk theory of xterm-likeness.

v3 replaces both halves. The database is gone
([§4](#4-the-terminfo-layer-and-its-decline)), `$TERM` is demoted to a color/legacy
hint — and, decisively for this survey, **tcell now interrogates**: its startup
negotiation sends `DECRQM` for its mouse/resize modes, the kitty keyboard query, the
xterm `modifyOtherKeys` query, and XTVERSION, ending with a DA1 fence the source marks
"MUST BE LAST" ([tcell v3 `vt/`][tcell-vt]). The project that invested most heavily in
the database model converged, independently, on the vaxis-shaped answer: a built-in
sequence model plus runtime queries behind a DA1 fence. Its testing seam evolved to
match — v2's [`SimulationScreen`][tcell-sim] (injectable keys, readable cell contents)
became v3's [`vt.MockTerm`][tcell-mock], a full terminal _emulator_ implementing
tcell's own `Tty` interface —
and tview inherits all of it unchanged through `tcell.NewScreen()`.

### vty and brick: the classic model, run honestly

vty (via `vty-unix`) is what disciplined terminfo consumption looks like. Output
capabilities come from `Terminfo.setupTerm` keyed on `$TERM`: `cup`/`sgr0`/`clear`/`el`
are hard requirements ("Terminal does not define required capability" — a startup
failure), ~17 style capabilities are probed individually and degrade to
silently-dropped styling when absent ([TerminfoBased.hs][vty-terminfo-based]). The
xterm-family special path is chosen by `$TERM` prefix (xterm/screen/tmux/rxvt) and
encodes its own era's folk knowledge — "If the terminal variant is xterm-color use
xterm instead since, more often than not, xterm-color is broken"
([XTermColor.hs][vty-xtermcolor]) — and _blindly_ enables UTF-8 charset, mouse, focus,
and bracketed-paste modes on the assumption that xterm-likes tolerate them.

Color depth shows the layering trap the charm stack avoided: `detectColorMode` reads
terminfo's `colors#` first and lets `COLORTERM=truecolor` upgrade the verdict **only
when the database already reports ≥ 256 colors**; if terminfo lookup fails outright,
the result is `NoColor` even with `COLORTERM` set ([Color.hs][vty-color]) — the
database retains veto power over fresher evidence, the inversion of colorprofile's
"maximum of env, terminfo, and tmux". The user override is a config file
(`~/.vty/config` `colorMode`), which vty's own docs say backends must respect "even
when their detection indicates that a different color mode should be used" — but
brick's `defaultMain` constructs vty with `defaultConfig`, never loading the user's
config file, so the override is dead in the most common consumption path. vty issues
no runtime queries of any kind (verified by absence across both repos), so brick
inherits a world where capability truth is whatever `$TERM` named — the exact posture
tcell v3 walked away from.

### notty: refusing the question

notty (OCaml, nottui's substrate) shows the floor of the design space: don't detect —
_decide_. Its capability model is a record of escape-emitting functions its own
interface documentation calls "A bundle of magic strings, really"
([notty.mli][notty-mli]), with exactly two instances: `ansi` and `dumb`. Selection is
six lines — `TERM` unset/empty/`dumb` means dumb, otherwise `isatty` picks ansi
([notty_unix.ml][notty-unix]) — and the ansi profile emits 24-bit SGR unconditionally,
with the docs stating the posture plainly: "No attempt is made to remap colors
depending on the terminal." No terminfo, no queries, no color tiers; width comes from
its own Unicode logic (`Uucp.Break.tty_width_hint`), not `wcwidth`. What redeems the
refusal architecturally is the seam it leaves open: every output entry point takes an
optional `?cap` parameter and rendering to a buffer is IO-free, so a caller who _does_
know better can inject a different profile. notty is what L0-only detection looks like
when it is a deliberate contract rather than an unexamined default — the null
hypothesis every detection layer in this survey must beat.

---

---

## 10. Hybrid detectors: crossterm, textual

Between the query-first and env-first poles sit the pragmatists: frameworks that query
for exactly the capabilities they need and guess the rest.

### crossterm: one perfect query, and guesses everywhere else

crossterm — the backend under ratatui and broot — ships the survey's most polished
_single_ probe. `supports_keyboard_enhancement` writes two sequences back-to-back
(`const QUERY: &[u8] = b"\x1B[?u\x1B[c";`) with the fence rationale spelled out in the
comment: "We send a query for the flags supported by the terminal and then the primary
device attributes query. If we receive the primary device attributes response but not
the keyboard enhancement flags, none of the flags are supported"
([terminal/sys/unix.rs][crossterm-unix], citing kitty's own detection doc). Every
operational lesson of [§5](#5-runtime-interrogation) is encoded: the query goes to
`/dev/tty` with an stdout fallback; raw mode is self-managed (enabled around the probe
if not already on); replies flow through the ordinary event parser as two internal
events, with a filter that accepts _either_ — answer or fence — as one wait; the fence
event is then explicitly drained from the queue; and a 2-second timeout converts the
no-tty case into a clean error. The docs' one warning is about event-loop ownership,
not raw mode: the probe "will block and possibly time out while `event::read` or
`event::poll` are being called" — the same query/event-loop collision bubbletea v1
patched with its `init` hack ([§8](#8-env-first-substrates-supports-color-termenv-colorprofile)).

Everything else in crossterm is a guess, and the source says so.
`available_color_count()` is a two-variable env sniff whose own doc admits "This does
not always provide a good result"; nothing in the SGR command path consults it —
`SetForegroundColor` emits unconditionally, with `NO_COLOR` honored at render time
inside `Colored`'s `Display` impl ([style.rs][crossterm-style]). On Windows the "query"
is the enable: try `SetConsoleMode` with `ENABLE_VIRTUAL_TERMINAL_PROCESSING` once,
cache the result, and fall back to 16-color WinAPI console attributes (with a GitBash
escape hatch that trusts a non-`dumb` `TERM` when the console calls fail) —
and `supports_keyboard_enhancement` is hardcoded `Ok(false)` there
([ansi_support.rs][crossterm-ansi-support]).

The consumption chain is its own finding: **ratatui core never calls the probe** — it
re-exports crossterm wholesale and leaves capability policy to applications. broot
reaches the probe only through crokey (which gates its key-combining feature on it),
sniffs truecolor itself from `COLORTERM` — _defaulting to true when unset_, with the
comment "this is debatable... I've found some terminals with COLORTERM unset but
supporting true colors" ([app_context.rs][broot-ctx]) — and detects light/dark
background via Canop's [terminal-light][terminal-light] crate (OSC 10/11 query with a
20 ms timeout, `COLORFGBG` fallback). One backend, three consumers, four detection policies: when the
substrate leaves capability policy open, every consumer grows its own.

### mosaic: the quiet convert

mosaic (Kotlin) is the survey's second conversion story after tcell. Earlier releases
delegated detection to the mordant library's env cascade; current mosaic interrogates
the terminal itself — a DA1 anchor, a batch of `DECRQM` and kitty probes plus
XTVERSION, a DSR end-marker, and a 1-second timeout — with the fence assumption stated
as a rhetorical question in the source: "In theory, there could exist a terminal which
does not respond to DA1 or DSR. Does that terminal actually work?"
([TtyTerminal.kt][mosaic-query]). Only its ANSI color _level_ still comes from env
(`NO_COLOR`/`COLORTERM`/`TERM`/`WT_SESSION`/`ConEmuANSI`). Its test seam survived the
conversion intact: `TestTerminal` implements the same `Terminal` interface with an
injectable all-on `Capabilities()` record ([TestTerminal.kt][mosaic-testterminal]) —
detection and rendering stay testable without a tty precisely because "terminal" is an
interface whose capabilities are plain data.

### textual: fire-and-forget, default-off

Textual (Python; [catalog dossier][textual-dossier]) queries for precisely two
capabilities — synchronized output ([mode 2026][mode-2026]) and in-band resize — and
treats both as pure upside. At startup the Linux driver writes `DECRQM` for mode 2026
and mode 2048 and simply returns: no fence, no deadline, no blocking. The reply, if one ever comes, is matched by the ordinary input parser's
mode-report regex ("Or a mode report? (i.e. the terminal saying it supports a mode we
requested)" — [\_xterm_parser.py][textual-parser]) and flips a single flag
(`App._sync_available`, default `False`); the only `CSI c` in the entire tree is a
_keymap entry_, not a fence. The cost model makes this coherent: a missed reply means
frames go out unsynchronized and `SIGWINCH` keeps handling resizes — degraded behavior,
never a hang. Where vaxis and notcurses buy certainty with a fence and (in notcurses'
case) risk an unbounded wait, Textual buys simplicity with silence-means-no.

Around those two queries sits a museum of terminal-specific patches that shows what
selective querying still can't avoid. The 2026 query is skipped entirely under
`TERM_PROGRAM=Apple_Terminal` — "Terminals should ignore this sequence if not
supported. Apple terminal doesn't, and writes a single 'p' into the terminal"
([linux_driver.py][textual-linux-driver]) — the emit-side hazard of
[§5](#5-runtime-interrogation), confirmed by this survey's own
[Apple Terminal row](#16-appendix-empirical-response-matrix). The 2048 _reply_ is
ignored under iTerm2 ("TODO: iTerm is buggy in one or more of the protocols required
here"), and ghostty's mouse coordinates get a workaround of their own. Meanwhile the
kitty keyboard protocol is never queried at all: Textual **pushes** the enhancement
flags blind (`CSI > flags u`), pops them on exit, and offers an env kill-switch
(`TEXTUAL_DISABLE_KITTY_KEY`) — leaning on the protocol's own design guarantee that
non-supporting terminals ignore the push. Color depth is delegated wholesale to Rich
(`Console(color_system="auto", force_terminal=True)`, overridable via
`TEXTUAL_COLOR_SYSTEM`), with `NO_COLOR` intercepted app-side and implemented as a
monochrome _filter_ over an internally-truecolor render pipeline
([app.py][textual-app]) — consent handled in the compositor, capability in the
delegate, queries in the driver: three different owners for the three detection
concerns.

---

---

## 11. The terminal-emulator side

Detection is a two-party protocol, and the emulators' own documentation shows what the
asking side can and cannot rely on.

**xterm's ctlseqs is the de-facto registry — and warns against itself.** Every query in
[§5](#5-runtime-interrogation)'s catalog is normatively described in
[xterm's control-sequences document][xterm-ctlseqs] (with the DEC originals at
vt100.net: [DA1][vt510-da1], [DA2][vt510-da2], [DECRQM][vt510-decrqm]): the DA1
attribute meanings ("Ps = 4 → Sixel graphics",
"Ps = 2 2 → ANSI color"), the DA2 `Pp;Pv;Pc` identity format, XTVERSION, XTGETTCAP's
`DCS 1 + r` valid / `DCS 0 + r` invalid split, DECRQM's five reply values, and the
OSC 10/11 `?` convention ("xterm replies with a control sequence of the same form which
can be used to set the corresponding dynamic color"). It also documents the limits of
identity queries in its own voice: "The VT100-style response parameters do not mean
anything by themselves", and even xterm's DA replies "depend on the decTerminalID
resource setting". DA2 identity is thoroughly debased in practice — VTE's source calls
its own DA2 reply "informational-only and should not be used by the host to detect
terminal features", tmux answers a code (`84`) that appears in no DEC table, and
Alacritty poses as `Pp = 0`, a VT100. Identity mimicry is why notcurses needs DA3,
XTVERSION, _and_ a quirk table — and why capability queries beat identity queries:
asking "do you honor mode 2026" needs no registry of who's who.

**kitty writes detection into its specs.** Each kitty protocol ships with a prescribed
detection recipe: the keyboard spec mandates the fence idiom — "If an answer for the
device attributes is received without getting back an answer for the progressive
enhancement the terminal does not support this protocol"
([keyboard protocol][kitty-kbd]) — and requires immediate reply ordering for graphics
queries ("terminal emulators that support the graphics protocol, must reply to query
actions immediately without processing other input" — [graphics protocol][kitty-gfx]);
the text-sizing spec uses a three-CPR cursor-movement probe (the vaxis trick of
[§7](#7-query-first-stacks-libvaxis-notcurses-termwiz) is an implementation of the
spec's own recipe, [text-sizing protocol][kitty-tsp]). kitty's refusals are equally
explicit: [mode 2027][mode-2027] is rejected by its author in favor of the
text-sizing approach
("I probably wont support 2027 as I have something better in mind" —
[kitty#7799][kitty-7799]) — which the [empirical matrix](#16-appendix-empirical-response-matrix)
shows as kitty's lone `2027 = 0` among the modern rows.

**foot documents the maximal answering surface; ghostty answers more than it
documents.** foot's man page is the fullest single inventory of query support any
terminal ships — DA1 ("I'm a VT220 with sixel and ANSI color support"), DA3 ("Foot
responds with \"FOOT\", in hexadecimal"), XTVERSION, XTGETTCAP ("Query builtin terminfo
database"), DECRQM for all five modern modes — and its README states the philosophy
from the responder's side: "Foot does **not** set any environment variables that can be
used to identify foot … You can instead use the escape sequences to read the
_Secondary_ and _Tertiary Device Attributes_" ([foot][foot-repo],
[foot-ctlseqs(7)][foot-ctlseqs]). ghostty's VT reference is younger and self-described
work-in-progress: DA1/DA2/XTVERSION/XTGETTCAP/DECRQM have no documentation pages, yet
the [empirical matrix](#16-appendix-empirical-response-matrix) shows ghostty answering
all of them (its source quacks "as a VT220"). foot has the inverse gap in miniature —
its docs list OSC 10/11 only as setters, but its source answers the `?` query form.
Both gaps teach the same lesson: **documentation lags the answering surface in both
directions, so the probe — not the docs — is the ground truth**, which is what makes an
empirical appendix worth maintaining at all.

**The advertisement half remains vendor-defined.** WezTerm exports
`TERM_PROGRAM=WezTerm` and ships an extended terminfo entry users must `tic -x`
themselves ([§7](#7-query-first-stacks-libvaxis-notcurses-termwiz)); ghostty ships
`xterm-ghostty` "to advertise its features" and grew an ssh automation layer for the
consequences ([§4](#4-the-terminfo-layer-and-its-decline)); iTerm2 pioneered
`TERM_PROGRAM` and a proprietary OSC 1337 family; Apple's Terminal answers three
queries total; and Alacritty refuses identity advertisement entirely, pointing
applications at the database ([§3](#3-the-environment-variable-layer)). Four postures —
advertise-by-env, advertise-by-database, advertise-by-answering, refuse — often within
one terminal. A detection library has to read all four dialects; the query battery is
the only channel every modern terminal speaks some of.

---

---

## 12. Failure modes and hostile environments

Every layer of [§2](#2-the-five-detection-layers) has an environment that defeats it.
The four below are not edge cases — between them they cover most real deployments.

### Multiplexers: the answering party is not the terminal

Inside tmux, screen, or zellij, every layer reports the _multiplexer_: `TERM` becomes
`tmux-256color`/`screen`, `TERM_PROGRAM` becomes `tmux`, and queries are answered by
the mux itself — truthfully, about itself (the
[detached-tmux row](#16-appendix-empirical-response-matrix): DA2 `84;0;0`, XTVERSION
`tmux 3.6a`, and OSC 10/11 silence because a detached server _has_ no colors). What
the mux doesn't understand, it eats: tmux's DCS dispatch handles sixel, DECRQSS, and
its own passthrough prefix, and silently drops everything else — an `XTGETTCAP` sent
into tmux is neither answered nor forwarded, it just vanishes (which is why fences
matter more, not less, under a mux). zellij's maintainer states the posture plainly:
"we have no choice but to swallow these, because for all intents and purposes we are
the terminal emulator for those tools … we also can't just pass them through as is"
([zellij#892][zellij-892]; passthrough remains an open request,
[zellij#3954][zellij-3954]).

Two structural consequences follow. First, **the mux is itself a detection client**:
tmux probes its outer terminal with DA/DSR ("tmux will also detect a few common
terminals from the DA and DSR responses" — [CHANGES][tmux-changes]) and, where
detection fails, makes the _user_ the capability database — the `terminal-features`
option ("this option can be used to easily tell tmux about features supported by
terminals it cannot detect", with flags like `256`, `RGB`, `extkeys`, `sync`,
`usstyle` — [tmux(1)][tmux-man]) — so an application's capability truth inside tmux is
capped by a hand-maintained config line outside it. Second, **capability growth
arrives release by release**, not by passthrough: tmux answered `DECRQM` for mouse
and paste modes in 3.6 and for mode 2026 in 3.7; GNU screen gained a `truecolor`
command only in 5.0 (2024) after two decades without it ([ChangeLog][screen-changelog]).
The sanctioned escape hatch, tmux's `allow-passthrough` ("Allow programs in the pane
to bypass tmux using a terminal escape sequence" — `DCS tmux; <seq> ST` with inner
escapes doubled, off by default — [tmux(1)][tmux-man]), reaches the outer terminal
but reintroduces the reordering hazard termwiz's 100 ms sleeps paper over
([§5](#5-runtime-interrogation)). For a detection library the rule is the one
principle 10 of [§15](#15-design-principles-for-a-sparkles-capability-detection-library)
draws: detect the mux, believe its answers _as the mux's_, and treat outer-terminal
knowledge as a separate, explicitly-requested layer.

### The SSH boundary: env dies, queries survive

The ssh protocol transports exactly one capability variable: `TERM`, carried inside
the `pty-req` message itself ("string TERM environment variable value" —
[RFC 4254 §6.2][rfc4254]). Everything else is deny-by-default on both ends — ssh's
`SendEnv` "default is not to send any environment variables"
([ssh_config(5)][ssh-config-sendenv]), sshd's `AcceptEnv` "default is not to accept
any environment variables" ([sshd_config(5)][sshd-config], with the RFC
calling uncontrolled env passing a "security hazard"). So on the far side of every
ssh hop, `COLORTERM`, `TERM_PROGRAM`, and the whole advertisement layer of
[§3](#3-the-environment-variable-layer) are simply gone, while `TERM` names a terminfo
entry the remote host may not have ([§4](#4-the-terminfo-layer-and-its-decline)'s
ghostty story). What crosses intact is the byte stream: queries and replies travel
the pty like any other IO — kitty's query kitten documents interrogation as the
SSH-proof channel ("it works over SSH as well", at the price of "a roundtrip" —
[query_terminal][kitty-query]). The remote-detection hierarchy is thus exactly
inverted from the local one: L3 is the _most_ reliable layer over ssh, L1 the least.

### Replies that outlive their reader

A query is a liability from the moment it is written until its reply is consumed. If
the program exits first, the reply arrives at whatever reads the terminal next —
usually the shell, where it appears as typed garbage
(`;rgb:1e1e/1e1e/1e1e…62;4;22c` at the prompt). The class is endemic: reported
against startup-querying CLI tools ([superset#4041][superset-4041]), against tmux
attach racing the client's own queries ([tmux#4535][tmux-4535]), and — in the other
temporal direction — against editors whose replies arrive _while the program runs_
and get parsed as keystrokes: neovim's background-color reply typed a literal `g`
into buffers ([neovim#11393][nvim-11393]), and the classic form — an OSC/DA reply
spilled into a vim buffer ending in `…[>85;95;0c` — predates them all
([Arch BBS, 2015][arch-199362]). The mitigations converge from three independent
directions: vim times its queries for when "there is no work to do" precisely "to
avoid the response to end up in a shell command or arrive after Vim exits"
([term.txt][vim-term]); zsh's line editor patches queries to run at startup with the
"DA query last" and pending input ungot; and this study's probe quiet-drains after
its fence ([§5](#5-runtime-interrogation)). The design rule: **whoever writes a query
owns its reply's entire lifetime** — fence it, drain it, and never exit between the
two.

### Windows: the API is the query, ConPTY is the mask

Windows makes half of this survey trivial and the other half strange. Trivial: the
capability check is an API call, and Microsoft documents detect-by-trying as the
official mechanism — "Checking whether SetConsoleMode returns 0 and GetLastError
returns ERROR*INVALID_PARAMETER is the current mechanism to determine when running on
a down-level system" ([console-virtual-terminal-sequences][console-vt-sequences]),
with VT sequences the recommended path forward and `GetConsoleMode` failure doubling
as the `isatty` test ([GetConsoleMode][getconsolemode]) — the exact pattern
[`detectTermCaps`][term-caps-src] and crossterm already implement. Strange: since
[ConPTY][conpty-blog], a translating renderer sits between the application and the
terminal — apps run "without any knowledge that its ConPTY ConHost is translating its
input/output" — so in-band interrogation reports \_ConPTY's* dialect, not Windows
Terminal's, and the real capability inventory lives in a version-tracked CSV with
separate ConsoleHost and Terminal columns ([master-sequence-list][master-sequence-list]).
The modern modes trickle in behind that mask (in-band resize is an open request —
[microsoft/terminal#19618][issue-19618]); meanwhile the env-var shortcut detectors
reach for, `WT_SESSION`, is broken in both directions — unset when Windows Terminal
is the default terminal ([#13006][issue-13006]) and inherited by processes that
aren't in it at all, with a maintainer sighing "we're fighting a losing battle
against people who are looking for WT_SESSION" ([#11057][issue-11057-dhowett]). The
surveyed libraries split accordingly: query-capable ones give Windows a hardcoded
profile (vaxis: "hard enable some knowns for ConPTY"; crossterm: `Ok(false)`), and
env-first ones fall back to OS build numbers — both are admissions that neither L1
nor L3 fully works there yet.

### Terminals that lie, and defaults that linger

Finally, the answers themselves have error bars. Identity replies are mimicked to the
point of uselessness ([§11](#11-the-terminal-emulator-side)); DA1 attribute lists
over- and under-claim (Alacritty's VT102-style DA1 has no room to advertise the sixel
support its forks have — notcurses scrubs and special-cases accordingly,
[§7](#7-query-first-stacks-libvaxis-notcurses-termwiz)); a terminal can _recognize_ a
mode yet ship it in a state the application must still set (the `DECRPM`
recognized-but-reset distinction the [probe][query-probe] reports raw); and the
environment inherits stale claims across context switches — the
[bare-pty rows](#16-appendix-empirical-response-matrix) carry a leaked
`TERM=xterm-256color` from a session that no longer exists, the same leak class that
misleads image-protocol detection in real tools (the yazi/TERM_PROGRAM incident class).
No single answer is authoritative; the robust posture is the one the layered designs
converged on — cross-check sources, prefer capability answers over identity answers,
record which source won ([§15](#15-design-principles-for-a-sparkles-capability-detection-library),
principles 4 and 13).

---

---

## 13. Comparative analysis

**Table A — detection inputs.** What each detector reads, and how it bounds the wait.

| Detector                                    | Env vars honored                                                        | Terminfo?                     | Runtime queries                                                                           | Fence                | Timeout                    | Layers   |
| ------------------------------------------- | ----------------------------------------------------------------------- | ----------------------------- | ----------------------------------------------------------------------------------------- | -------------------- | -------------------------- | -------- |
| Sparkles [`term_caps`][term-caps-src]       | NO_COLOR, CLICOLOR_FORCE, TERM, COLORTERM, locale                       | no                            | none                                                                                      | n/a                  | n/a                        | L0–L1    |
| [supports-color][supports-color-index]/ink  | FORCE_COLOR, TERM, COLORTERM, TERM_PROGRAM(+VERSION), CI vars, TF_BUILD | no                            | none (ink: opt-in kitty `CSI ?u`)                                                         | none (ink: none)     | ink probe: 200 ms          | L0–L1    |
| [termenv][tv-unix] (bubbletea v1)           | NO_COLOR, CLICOLOR(\_FORCE), COLORTERM, TERM, TERM_PROGRAM, CI          | no                            | OSC 10/11                                                                                 | CPR (`CSI 6n`)       | 5 s                        | L0–L1+L3 |
| [colorprofile][cp-env] (bubbletea v2)       | NO_COLOR, CLICOLOR(\_FORCE), COLORTERM, TERM(\_PROGRAM), WT_SESSION     | yes (`Tc`/`RGB`)              | `tmux info` subprocess; bubbletea v2: XTGETTCAP `RGB`/`Tc`, opt-in OSC 11                 | DA1 (lipgloss v2)    | 2 s                        | L0–L3    |
| [crossterm][crossterm-unix] (ratatui/broot) | COLORTERM, TERM, NO_COLOR                                               | no                            | kitty `CSI ?u`                                                                            | DA1                  | 2 s                        | L0–L1+L3 |
| [tcell v2][tcell-v2]                        | TERM, COLORTERM                                                         | yes (compiled-in + `infocmp`) | none                                                                                      | n/a                  | n/a                        | L0–L2    |
| [tcell v3][tcell-vt]                        | TERM (hint), COLORTERM, TERM_PROGRAM                                    | no (built-in VT model)        | DECRQM modes, kitty `CSI ?u`, `CSI ?4m`, XTVERSION                                        | DA1 ("MUST BE LAST") | yes                        | L0–L3    |
| [vty][vty-terminfo-based]/brick             | TERM, COLORTERM                                                         | yes (classic)                 | none                                                                                      | n/a                  | n/a                        | L0–L2    |
| [notty][notty-unix]/nottui                  | TERM (dumb check only)                                                  | no                            | none                                                                                      | n/a                  | n/a                        | L0       |
| [termwiz][termwiz-mod]                      | TERM, COLORTERM(\_BCE), TERM_PROGRAM(+VERSION), NO_COLOR                | yes (one input)               | opt-in: XTVERSION, `CSI 16t`/`18t`                                                        | DA1                  | none (100 ms sleeps)       | L0–L3    |
| [textual][textual-linux-driver]             | TEXTUAL\_\*, NO_COLOR, TERM_PROGRAM, LC_TERMINAL                        | no (Rich delegates)           | DECRQM 2026, 2048                                                                         | **none**             | none (default-off)         | L0–L1+L3 |
| [mosaic][mosaic-query]                      | NO_COLOR, COLORTERM, TERM, WT_SESSION, ConEmuANSI                       | no                            | DA1, DECRQM batch, kitty probes, XTVERSION                                                | DA1 + DSR            | 1 s                        | L0–L1+L3 |
| [notcurses][nc-termdesc]                    | COLORTERM, TERM, TERM_PROGRAM                                           | yes (required baseline)       | DA1/2/3, XTVERSION, XTGETTCAP, DECRQM, OSC 4/10/11, kitty kbd+gfx, XTSMGRAPHICS, geometry | DA1                  | **none** (documented hang) | L0–L4    |
| [libvaxis][vaxis-src]                       | VAXIS*FORCE*\*, VHS_RECORD, TERMUX_VERSION, TERM_PROGRAM                | no                            | DECRQM 1016/2027/2031, XTVERSION, kitty `?u`+APC, OSC 66 probes, CPR                      | DA1 (futex)          | caller (1 s convention)    | L0–L4    |

**Table B — engineering choices.**

| Detector              | Caps data model                         | Disable vs force                        | Windows path                               | Mux awareness                            | Testability seam                            | Queries opt-in?            |
| --------------------- | --------------------------------------- | --------------------------------------- | ------------------------------------------ | ---------------------------------------- | ------------------------------------------- | -------------------------- |
| Sparkles today        | `TermCaps` value struct                 | disable beats force                     | VT enable + code page                      | none                                     | pure [`classifyColorDepth`][term-color-src] | n/a                        |
| supports-color/chalk  | level 0–3 per stream                    | FORCE_COLOR beats all (also a floor)    | `os.release()` build numbers               | none                                     | `createSupportsColor(stream, opts)`         | n/a                        |
| termenv               | Profile enum (Ascii…TrueColor)          | NO_COLOR beats CLICOLOR_FORCE           | separate `_windows.go`                     | screen capped; OSC refused under mux     | `Environ` interface injection               | lazy, on first use         |
| colorprofile/charm v2 | Profile enum + `NoTTY` rung             | NO_COLOR beats force (ParseBool bug)    | `RtlGetNtVersionNumbers` builds            | `tmux info` subprocess                   | `Detect(output, env []string)`              | opt-in commands            |
| crossterm             | bool + flags per query                  | NO_COLOR at render time; force override | try-enable-VT once, cache; WinAPI fallback | none                                     | none (events only)                          | explicit function call     |
| tcell v2 → v3         | terminfo struct → built-in VT profiles  | n/a                                     | console API screen                         | tmux entries in DB → hint                | `SimulationScreen` → `vt.MockTerm` emulator | v3: automatic at init      |
| vty/brick             | terminfo caps + ColorMode               | config file (dead under `defaultMain`)  | separate vty-windows                       | TERM-prefix lump (screen=xterm-like)     | none surveyed                               | never                      |
| notty                 | two `Cap` profiles (ansi/dumb)          | n/a                                     | none (unix only)                           | none                                     | `?cap` parameter, IO-free render            | never                      |
| termwiz               | `Capabilities` value + `ProbeHints`     | NO_COLOR → MonoChrome hint              | bundled xterm-256color entry               | tmux passthrough envelopes + quirk table | hints as plain data                         | explicit, separate layer   |
| textual               | scattered flags (`_sync_available`)     | NO_COLOR as render filter               | VT enable, no queries                      | none (Apple/iTerm quirks only)           | env-var driver injection                    | automatic, fire-and-forget |
| mosaic                | `Capabilities` record                   | NO_COLOR in env level                   | WT_SESSION/ConEmuANSI                      | none                                     | `TestTerminal` interface impl               | automatic at init          |
| notcurses             | `tinfo` struct (mixed provenance)       | n/a                                     | ConHost special case                       | screen DA2 versioning; tmux "FIXME"      | none (notcurses-info tool)                  | automatic, blocking        |
| libvaxis              | `Capabilities` bool struct + width enum | env overrides pre-empt detection        | no detection, "hard enable" ConPTY         | none                                     | parser is pure over bytes                   | automatic with timeout     |

Five observations carry the survey's weight:

1. **Env-only detectors are color-only detectors** — every Table A row without an L3
   entry detects nothing beyond color depth and tty-ness ([§2](#2-the-five-detection-layers)).
   The moment a library needs a second capability class, it either queries (ink,
   crossterm, textual) or hardcodes terminal names (the pattern every source that
   comments on it disavows).
2. **Everything that queries converged on the same fence.** DA1 for vaxis, notcurses,
   crossterm, tcell v3, mosaic, lipgloss v2, termwiz; CPR for termenv (and vaxis's
   movement probes). Nobody invented a third mechanism — this is as close to a
   standard as an unstandardized space gets.
3. **The migrations all point one way.** tcell v2→v3 (database → queries), mosaic
   (mordant env cascade → queries), charm v1→v2 (import-time env detection → explicit
   startup detection + runtime capability upgrades), ink (whitelist → opt-in probe),
   textual (`_terminal_features` NamedTuple → per-mode queries). No surveyed project
   moved _toward_ the database or _toward_ richer env sniffing.
4. **Timeout policy is the least-converged decision** — from notcurses' none-and-hang
   through textual's none-and-default-off to deadlines spanning 200 ms–5 s. The two
   "none" postures bracket the space: certainty-or-hang vs availability-with-degradation.
5. **The best testability seams treat environment and terminal as data** — colorprofile's
   `Detect(output, env)`, termenv's `Environ`, mosaic's `TestTerminal`, tcell v3's
   `MockTerm`, notty's `?cap`. Detectors that read globals (supports-color's
   import-time snapshot, ncurses' `cur_term`) are the ones whose behavior tests can't
   pin down.

---

---

## 14. Analysis through Sean Parent's principles

**Value semantics: the capability snapshot wants to be a value.** The oldest API in
this survey is also the most instructive negative example: classic terminfo's
`setupterm` "stores its information about the terminal in a `TERMINAL` structure
pointed to by the global variable `cur_term`" ([curs_terminfo(3x)][curs_terminfo]) —
every capability read is a read of ambient mutable process state, and multi-terminal
programs must swap the global. Every modern design in the survey moved to a copyable
value: vaxis's `Capabilities` struct of booleans, termwiz's `Capabilities` +
`ProbeHints`, mosaic's `Capabilities` record, supports-color's level object, Sparkles'
own [`TermCaps`][term-caps-src]. Values compose ([value semantics][sean-parent-vs]):
they can be snapshotted per stream (supports-color's separate stdout/stderr verdicts),
overridden wholesale (termwiz hints), injected into tests (mosaic), and threaded
through rendering as plain arguments — which is precisely the existing Sparkles
contract ("renderers stay pure producers; apps call `detectTermCaps` once and thread
the fields through").

**The incidental data structure: detection provenance.** Parent's test — is there a
structure the program _needs_ that no object represents
([data structures][sean-parent-ds])? Here, universally, yes: **where each capability
fact came from.** notcurses' `tinfo` mixes terminfo lookups, env overrides, query
replies, and per-terminal heuristic fixups into one struct with no record of which
source won; the debugging tool that reconstructs the answer (`notcurses-info`) exists
precisely because the data structure doesn't hold it. vaxis's `caps.rgb` sat
producerless for months without the type system noticing, because a `bool` cannot say
"nobody ever set me — this is the default, not a finding". The distinction between
_measured-yes_, _inferred-yes_, _defaulted-no_, and _user-forced_ is load-bearing at
exactly the moments that matter — conflict resolution
([§3](#3-the-environment-variable-layer)'s precedence table is nothing but this),
cache invalidation, and bug reports — and no surveyed library represents it. This is
the clearest structural gap a new design can close.

**Algorithms separated from data.** The healthiest code in the survey makes the
detection _decision_ a pure function over explicit inputs and confines IO to the
edges: colorprofile's `Detect(output, env []string)`, termenv's `Environ` interface,
supports-color's `createSupportsColor(stream)` — and, at the reply-handling end,
vaxis's `Parser` (pure bytes → events, with the event loop applying state) versus
notcurses' automaton whose callbacks mutate shared state under a lock ("very delicate!
hands off!" — [in.c][nc-in]). Sparkles' [`classifyColorDepth`][term-color-src] —
`(colorterm, term) → ColorDepth`, CTFE-able, no environment reads — is already the
right shape; the survey's lesson is to keep every new classifier (DECRPM values →
mode state, XTGETTCAP payload → capability, DA1 attributes → feature bits) in exactly
that form, with the query round-trip as a thin IO shell around a pure response parser
— which is also what makes the [empirical matrix](#16-appendix-empirical-response-matrix)
double as a fixture corpus.

**Design by Introspection.** The D-specific translation
([DbI guidelines][dbi-guidelines]): capability consumers should adapt to what the
capability _value_ offers, not to a type hierarchy of terminals. tcell v3's discovery
that "pretty much all of the terminal logic can be consolidated to just a few classes
of terminals with substantial overlap" is a runtime restatement of the DbI premise —
terminals differ by feature presence, not by kind. A `TermCaps`-style struct whose
optional facets are detected via traits (`static if (hasGraphics!Caps)`) lets the same
rendering pipeline serve a dumb pipe, a 16-color CI log, and a kitty-graphics terminal
without a class for each — the shell-with-hooks pattern the repo already uses
elsewhere, applied to the capability seam.

---

---

## 15. Design principles for a Sparkles capability-detection library

Synthesizing the survey for the library that lifts [`term_caps`][term-caps-src] past
its deliberate env + ioctl boundary:

### 1. Layers form a pipeline: L0 gates, L1 consents and guesses, L3 refines, L4 subscribes

Follow the shape every mature detector converged on
([§2](#2-the-five-detection-layers)): stream introspection decides whether escapes are
emitted at all; the environment carries the user's consent (which nothing deeper may
override) plus a free first estimate; interrogation upgrades the estimate;
subscriptions keep it current. colorprofile's one-liner — "Color profile is the maximum
of env, terminfo, and tmux" — and bubbletea v2's runtime upgrades are the working
precedents ([§8](#8-env-first-substrates-supports-color-termenv-colorprofile)).

### 2. No terminfo; hardcoded sequences plus interrogation

The evidence is unanimous — vaxis never had it, tcell deleted it, notcurses wishes it
could ("ideally we'd abandon terminfo entirely"), and the terminals themselves route
around it ([§4](#4-the-terminfo-layer-and-its-decline)). Sparkles'
[`term_control`][term-control-src] already commits to hardcoded sequences; extend that
posture to detection. `XTGETTCAP` covers the residual terminfo-shaped facts (`RGB`,
`Tc`, `Su`) directly from the terminal — no database file, no `$TERM` key.

### 3. The capability snapshot stays a plain value

Extend the existing [`TermCaps`][term-caps-src] contract — copyable, comparable,
threadable through renderers as an argument — never a global
([§14](#14-analysis-through-sean-parents-principles)). Per-stream snapshots
(supports-color's stdout/stderr split) fall out for free when detection is a function
of an explicit stream.

### 4. Record provenance per fact

The gap every surveyed library shares: a `bool` cannot distinguish measured-yes from
defaulted-no from user-forced ([§14](#14-analysis-through-sean-parents-principles);
vaxis's producerless `rgb` is the cautionary tale). Make the distinction a type:

```d
enum Provenance : ubyte { defaulted, environment, query, userOverride }

struct Detected(T)
{
    T value;
    Provenance src;
    alias value this; // reads stay ergonomic; provenance rides along
}
```

Conflict resolution ([§3](#3-the-environment-variable-layer)'s precedence table),
debug output (`notcurses-info`-style dumps), and cache invalidation all become
operations over data instead of folklore.

### 5. Pure, CTFE-able classifiers; IO only at the edge

Generalize the [`classifyColorDepth`][term-color-src] pattern: every mapping from
evidence to verdict — DECRPM value → mode state, `XTGETTCAP` payload → capability,
DA1 attributes → feature bits, env tuple → color tier — is a pure function over
explicit inputs, unit-testable at compile time (vaxis's [Parser.zig][vaxis-parser] is
the pure-bytes-to-events precedent). The query round-trip is a thin
`@nogc`-conscious shell (write batch, deadline-read, hand bytes to the pure parser),
reusing [`byAnsiToken`][ansi-src]'s escape grammar exactly as the
[probe][query-probe] already does.

### 6. One batched write, a DA1 fence, a deadline — and drain what you started

The pattern seven independent implementations converged on
([§5](#5-runtime-interrogation)):

```d
Expected!(QueryReport, QueryError) interrogate(
    scope ref RawTty tty,
    in QuerySet queries,
    Duration deadline = 1.seconds)
```

Batch all queries in one flush ending with `CSI c`; read until a complete DA1 reply or
the deadline (real terminals answer in single-digit milliseconds — the
[matrix](#16-appendix-empirical-response-matrix) measured 1–20 ms — so the deadline is
insurance, not latency); then quiet-drain so unconsumed replies never leak into the
parent shell ([§5](#5-runtime-interrogation)'s leakage hazard). Never wait unbounded:
notcurses' documented hang is the counterexample that costs users.

### 7. Interrogation is opt-in and tty-gated; the env path stays the default

`detectTermCaps()` remains the cheap, non-invasive snapshot every CLI tool calls.
Interrogation is a separate, explicit call for interactive programs — crossterm's
standalone function and bubbletea v2's opt-in commands are the models, and the
bubbletea v1 `tea_init` hang-workaround is the cost of making it implicit
([§8](#8-env-first-substrates-supports-color-termenv-colorprofile),
[§10](#10-hybrid-detectors-crossterm-textual)). Both stdin and stdout must be real
terminals, mirroring [`key_input`][key-input-src]'s gate; prefer the controlling
terminal over raw stdin/stdout (vaxis opens `/dev/tty`; termenv refuses background
processes).

### 8. Consent is law, parsed exactly

Resolution order: explicit API flag, then `NO_COLOR` (any non-empty value — not
`ParseBool`; colorprofile's `NO_COLOR=yes` bug is the caution), then
`CLICOLOR_FORCE`/`FORCE_COLOR`, then detection — and **disable beats force**, which
[`detectTermCaps`][term-caps-src] already implements
([§3](#3-the-environment-variable-layer)). Consent gates _emission_; it never mutates
the classified _capability_ (the `term_color` module-header split, kept).

### 9. Degradation ladders, not booleans

Monotone enums per capability class, so consumers write `caps.color >= ColorDepth.ansi256`
instead of feature-flag soup: the existing `ColorDepth` ladder, plus
`none < sixel < kitty` for graphics, `legacy < kittyFlags` for keyboard — with an
explicit bottom rung for "not a terminal" (colorprofile's `NoTTY` insight). Every
ladder's floor is the [empirical matrix](#16-appendix-empirical-response-matrix)'s
GNU-screen row: DA1, DA2, and nothing else.

### 10. Multiplexers are subjects, not noise

Detect them from `TMUX`/`STY`/`ZELLIJ` and `TERM` prefixes; then still interrogate —
the answers are _true_, they just describe the mux
([§16](#16-appendix-empirical-response-matrix)'s detached-tmux row). Record
mux-ness in the snapshot (it downgrades trust in env advertisement and gates
OSC color queries, per termenv's refusal), and treat passthrough as a distinct,
later feature (termwiz's envelopes show both the mechanism and the reordering cost).

### 11. Windows is the same seam, different verbs

`GetConsoleMode` is `isatty`; try-`SetConsoleMode`-and-cache is the capability query;
ConPTY-era Windows Terminal answers real VT queries while legacy conhost answers
nothing — which the deadline already handles. Keep it behind the same
`Detected!`-valued interface (crossterm's try-enable-cache and vaxis's "hard enable
some knowns for ConPTY" are the two working postures;
[§12](#12-failure-modes-and-hostile-environments)).

### 12. Subscriptions need an event seam, not just a struct

Modes 2048/2031, kitty's flag stack, and `SIGWINCH` deliver capability _changes_
([§6](#6-negotiation-and-subscription-capabilities)). Alongside the snapshot, expose a
hook the reply-parser can drive:

```d
// DbI shell-with-hooks: the loop adapts to whatever the app's handler accepts.
static if (is(typeof(hooks.onResize)))
    case winsizeReport: hooks.onResize(parseWinsize(payload)); break;
static if (is(typeof(hooks.onColorScheme)))
    case dsr997: hooks.onColorScheme(parseScheme(payload)); break;
```

vaxis (capability events in the input loop) and bubbletea v2 (capability messages)
are the two proofs this composes with an application event loop.

### 13. Capability queries over identity queries; quirks as data, last

Prefer "do you honor mode 2026" to "who are you": DA2/XTVERSION identities are
mimicked, resource-dependent, and registry-bound
([§11](#11-the-terminal-emulator-side)), and notcurses' twenty-terminal fixup table
shows where identity-keyed detection ends ("le sigh" —
[§7](#7-query-first-stacks-libvaxis-notcurses-termwiz)). Where a quirk is unavoidable
(Terminal.app's query bleed, iTerm2's buggy 2048), express it as a small data table
keyed on the _already-collected_ identity answers — never as the primary mechanism.

### 14. Detection is a function of data; tests inject the data

`(env, ttyness, replyBytes) → TermCaps` with no hidden global reads — colorprofile's
`Detect(output, env)`, termenv's `Environ`, mosaic's `TestTerminal` and tcell v3's
`MockTerm` are the seams that kept their libraries testable
([§13](#13-comparative-analysis)). The [empirical matrix](#16-appendix-empirical-response-matrix)
doubles as the fixture corpus: each row's raw replies replay through the pure parser
as a regression test, no tty required.

### 15. Ship the inspector

`notcurses-info`, `kitten query-terminal`, and this study's [probe][query-probe] all
exist because detection bugs are environmental: the report that shows _what was asked,
what answered, and what was concluded_ (with provenance, per principle 4) is the
difference between a fixable bug report and a shrug. The probe graduates into the
library as its debugging front-end.

---

---

## 16. Appendix: empirical response matrix

Documentation says what a terminal _should_ answer; this appendix records what
terminals _actually_ answered. The co-located probe, [`examples/query-probe.d`][query-probe]
(a dub single-file program registered with the repository's `ci --example-files`
suite), sends the full query battery of [§5](#5-runtime-interrogation) in one write —
`XTVERSION`, kitty keyboard, `DECRQM` for modes 2004/2026/2027/2031/2048, `XTGETTCAP`
for `RGB`/`Tc`/`Su`, OSC 10/11, the kitty graphics query, and secondary DA — fenced by
primary DA with a 1-second deadline, then classifies replies by shape. Each row below
is the probe's `--markdown` output run inside one terminal; `—` means "no reply before
the fence". `DECRQM` cells hold the raw `DECRPM` value (0 = not recognized,
1 = set, 2 = recognized but reset, 3/4 = permanently set/reset) — the
recognized-but-reset distinction is itself a capability signal no database can supply.

| Terminal                     | TERM           | COLORTERM | DA1      | DA2        | XTVERSION     | kitty-kbd | 2004 | 2026 | 2027 | 2031 | 2048 | RGB     | Tc  | Su  | OSC 10             | OSC 11             | kitty-gfx |
| ---------------------------- | -------------- | --------- | -------- | ---------- | ------------- | --------- | ---- | ---- | ---- | ---- | ---- | ------- | --- | --- | ------------------ | ------------------ | --------- |
| bare-pty-no-emulator (Linux) | xterm-256color | —         | —        | —          | —             | —         | —    | —    | —    | —    | —    | —       | —   | —   | —                  | —                  | —         |
| bare-pty-no-emulator (macOS) | —              | —         | —        | —          | —             | —         | —    | —    | —    | —    | —    | —       | —   | —   | —                  | —                  | —         |
| tmux-3.6a-detached           | tmux-256color  | truecolor | 1;2;4    | 84;0;0     | tmux 3.6a     | —         | 2    | —    | —    | 2    | —    | —       | —   | —   | —                  | —                  | —         |
| GNU-Screen-4.00.03 (macOS)   | screen         | —         | 1;2      | 83;40003;0 | —             | —         | —    | —    | —    | —    | —    | —       | —   | —   | —                  | —                  | —         |
| Apple-Terminal (macOS 26.3)  | xterm-256color | truecolor | 1;2      | 1;95;0     | —             | —         | —    | —    | —    | —    | —    | —       | —   | —   | rgb:ffff/ffff/ffff | rgb:1e1e/1e1e/1e1e | —         |
| kitty-0.44.0 (Linux)         | xterm-kitty    | truecolor | 62;52;   | 1;4000;44  | kitty(0.44.0) | 0         | 2    | 2    | 0    | 2    | 2    | invalid | ok  | ok  | rgb:dddd/dddd/dddd | rgb:0000/0000/0000 | OK        |
| ghostty-1.3.1 (Linux)        | xterm-ghostty  | truecolor | 62;22;52 | 1;10;0     | ghostty 1.3.1 | 0         | 2    | 2    | 1    | 2    | 2    | 8       | ok  | ok  | rgb:ffff/ffff/ffff | rgb:2828/2c2c/3434 | OK        |
| ghostty-1.3.1 (macOS 26.3)   | xterm-ghostty  | truecolor | 62;22;52 | 1;10;0     | ghostty 1.3.1 | 0         | 2    | 2    | 1    | 2    | 2    | 8       | ok  | ok  | rgb:f0f0/f3f3/f6f6 | rgb:0a0a/0c0c/1010 | OK        |

Collection notes, in row order:

- The two **bare-pty** rows are pseudo-terminals with no emulator behind them
  (`script(1)` on both OSes): `isatty` is true, every query times out — the
  L0-passes/L3-fails case a timeout policy exists for. The Linux row's `TERM` is
  leaked from the launching session (a live specimen of environment hearsay); the
  macOS row ran under a non-interactive ssh session with no `TERM` at all.
- The **tmux** row is a _detached_ server answering for itself: it identifies via
  `XTVERSION`/DA2 (`84` is ASCII `T`), recognizes modes 2004/2031, but with no client
  attached answers **nothing** for OSC 10/11 — a capability that appears and
  disappears with attachment state.
- **GNU screen 4.00.03** (the copy macOS still ships, released 2006) answers exactly
  the two 1980s queries — DA1 `1;2` (VT100-with-AVO) and DA2 (`83` is ASCII `S`) —
  and is silent for everything else: the "ancient multiplexer" floor a degradation
  ladder must land on.
- **Apple Terminal on macOS 26.3** answers DA1 with the same `1;2` VT100-class reply
  as 2006-era screen, plus DA2 and OSC 10/11 — and nothing else. Two details are
  load-bearing. First, it now exports `COLORTERM=truecolor`, while supports-color's
  whitelist still grades `Apple_Terminal` at 256-color — hardcoded terminal knowledge
  rots in _both_ directions. Second, the `DECRQM` silence corroborates Textual's
  documented reason for skipping the query there entirely (it bleeds a literal `p`
  into the output on older releases — [linux_driver.py][textual-linux-driver]).
- The **kitty and ghostty** rows were collected headlessly (`xvfb-run` on Linux,
  LaunchServices on macOS) and disagree in exactly the ways that make interrogation
  necessary: kitty answers `XTGETTCAP Tc`/`Su` but rejects `RGB` as invalid, while
  ghostty answers all three; kitty reports mode 2027 as _not recognized_ (0) where
  ghostty reports it _set by default_ (1).
- **ghostty's two rows are capability-identical across Linux and macOS** (only the
  theme colors differ) — with a query-first terminal the capability profile travels
  with the terminal, not the OS, which is precisely what makes interrogation portable
  where env/database heuristics are not.

Additional rows (zellij, WezTerm, foot, xterm, iTerm2, tmux-attached, ssh chains)
paste in directly from `dub run --single query-probe.d -- --markdown` run in the
terminal of interest.

---

## References

[tui-index]: index.md
[comparison]: comparison.md
[tree-view-case-study]: tree-view-case-study.md
[table-span-case-study]: table-span-case-study.md
[libvaxis-dossier]: libvaxis.md
[notcurses-dossier]: notcurses.md
[textual-dossier]: textual.md
[bubbletea-dossier]: bubbletea.md
[sean-parent-index]: ../sean-parent/index.md
[sean-parent-vs]: ../sean-parent/value-semantics.md
[sean-parent-ds]: ../sean-parent/data-structures.md
[dbi-guidelines]: ../../guidelines/design-by-introspection-01-guidelines.md
[functional-guidelines]: ../../guidelines/functional-declarative-programming-guidelines.md
[tui-spec]: ../../specs/core-cli/tui-components/index.md
[term-caps-src]: ../../../libs/core-cli/src/sparkles/core_cli/term_caps.d
[term-color-src]: ../../../libs/base/src/sparkles/base/term_color.d
[term-control-src]: ../../../libs/base/src/sparkles/base/term_control.d
[key-input-src]: ../../../libs/core-cli/src/sparkles/core_cli/key_input.d
[ansi-src]: ../../../libs/base/src/sparkles/base/text/ansi.d
[query-probe]: examples/query-probe.d

## External Sources

[no-color]: https://no-color.org/
[no-color-src]: https://github.com/jcs/no_color/blob/master/index.md
[clicolors]: https://bixense.com/clicolors/
[freebsd-ls]: https://man.freebsd.org/cgi/man.cgi?query=ls&sektion=1
[supports-color-index]: https://github.com/chalk/supports-color/blob/main/index.js
[supports-color-readme]: https://github.com/chalk/supports-color/blob/main/readme.md
[chalk-index]: https://github.com/chalk/chalk/blob/main/source/index.js
[ink-ink-tsx]: https://github.com/vadimdemedes/ink/blob/master/src/ink.tsx
[ink-colorize]: https://github.com/vadimdemedes/ink/blob/master/src/colorize.ts
[is-in-ci]: https://github.com/sindresorhus/is-in-ci
[tv-unix]: https://github.com/muesli/termenv/blob/master/termenv_unix.go
[tv-go]: https://github.com/muesli/termenv/blob/master/termenv.go
[cp-env]: https://github.com/charmbracelet/colorprofile/blob/main/env.go
[bt1-init]: https://github.com/charmbracelet/bubbletea/blob/v1.3.10/tea_init.go
[bt2-tea]: https://github.com/charmbracelet/bubbletea/blob/main/tea.go
[lg2-terminal]: https://github.com/charmbracelet/lipgloss/blob/main/terminal.go
[termstandard]: https://github.com/termstandard/colors/blob/master/README.md
[term7]: https://invisible-island.net/ncurses/man/term.7.html
[terminfo5]: https://invisible-island.net/ncurses/man/terminfo.5.html
[tic1]: https://invisible-island.net/ncurses/man/tic.1m.html
[curs_terminfo]: https://invisible-island.net/ncurses/man/curs_terminfo.3x.html
[user_caps5]: https://invisible-island.net/ncurses/man/user_caps.5.html
[ncurses-faq]: https://invisible-island.net/ncurses/ncurses.faq.html
[ncurses-61]: https://invisible-island.net/ncurses/announce-6.1.html
[tctest]: https://invisible-island.net/ncurses/tctest.html
[unibilium]: https://github.com/neovim/unibilium
[unibilium-readme]: https://github.com/neovim/unibilium/blob/master/README.md
[tmux-faq]: https://github.com/tmux/tmux/wiki/FAQ
[tmux-environ]: https://github.com/tmux/tmux/blob/master/environ.c
[tmux-changes]: https://github.com/tmux/tmux/blob/master/CHANGES
[tmux-man]: https://man.openbsd.org/tmux
[screen-changelog]: https://git.savannah.gnu.org/cgit/screen.git/tree/src/ChangeLog?h=v.5.0.0
[zellij-892]: https://github.com/zellij-org/zellij/issues/892
[zellij-3954]: https://github.com/zellij-org/zellij/issues/3954
[ghostty-terminfo]: https://ghostty.org/docs/help/terminfo
[ghostty-ssh]: https://ghostty.org/docs/features/ssh
[devlog004]: https://mitchellh.com/writing/ghostty-devlog-004
[libvaxis]: https://github.com/rockorager/libvaxis
[tcell-v2]: https://github.com/gdamore/tcell/tree/v2
[tcell-changesv3]: https://github.com/gdamore/tcell/blob/main/CHANGESv3.md
[kitty-underlines]: https://sw.kovidgoyal.net/kitty/underlines/
[kitty-kbd]: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
[kitty-gfx]: https://sw.kovidgoyal.net/kitty/graphics-protocol/
[kitty-tsp]: https://sw.kovidgoyal.net/kitty/text-sizing-protocol/
[kitty-7799]: https://github.com/kovidgoyal/kitty/issues/7799
[mode-2026]: https://contour-terminal.org/vt-extensions/synchronized-output/
[mode-2027]: https://github.com/contour-terminal/terminal-unicode-core
[mode-2031]: https://contour-terminal.org/vt-extensions/color-palette-update-notifications/
[mode-2048]: https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83
[xterm-ctlseqs]: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
[vt510-da1]: https://vt100.net/docs/vt510-rm/DA1.html
[vt510-da2]: https://vt100.net/docs/vt510-rm/DA2.html
[vt510-decrqm]: https://vt100.net/docs/vt510-rm/DECRQM.html
[foot-repo]: https://codeberg.org/dnkl/foot
[foot-ctlseqs]: https://codeberg.org/dnkl/foot/src/branch/master/doc/foot-ctlseqs.7.scd
[ssh-config-sendenv]: https://man.openbsd.org/ssh_config#SendEnv
[rfc4254]: https://datatracker.ietf.org/doc/html/rfc4254#section-6.2
[kitty-query]: https://sw.kovidgoyal.net/kitty/kittens/query_terminal/
[tmux-4535]: https://github.com/tmux/tmux/issues/4535
[nvim-11393]: https://github.com/neovim/neovim/issues/11393
[arch-199362]: https://bbs.archlinux.org/viewtopic.php?id=199362
[vim-term]: https://vimhelp.org/term.txt.html
[console-vt-sequences]: https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences
[getconsolemode]: https://learn.microsoft.com/en-us/windows/console/getconsolemode
[conpty-blog]: https://devblogs.microsoft.com/commandline/windows-command-line-introducing-the-windows-pseudo-console-conpty/
[master-sequence-list]: https://github.com/microsoft/terminal/blob/main/doc/reference/master-sequence-list.csv
[issue-19618]: https://github.com/microsoft/terminal/issues/19618
[issue-13006]: https://github.com/microsoft/terminal/issues/13006
[issue-11057-dhowett]: https://github.com/microsoft/terminal/issues/11057#issuecomment-909369514
[alacritty-4793]: https://github.com/alacritty/alacritty/issues/4793
[sshd-config]: https://man.openbsd.org/sshd_config#AcceptEnv
[notcurses]: https://github.com/dankamongmen/notcurses
[nc-termdesc]: https://github.com/dankamongmen/notcurses/blob/master/src/lib/termdesc.c
[nc-termdesc-h]: https://github.com/dankamongmen/notcurses/blob/master/src/lib/termdesc.h
[nc-in]: https://github.com/dankamongmen/notcurses/blob/master/src/lib/in.c
[nc-terminals]: https://github.com/dankamongmen/notcurses/blob/master/TERMINALS.md
[nc-info]: https://github.com/dankamongmen/notcurses/blob/master/doc/man/man1/notcurses-info.1.md
[vaxis-src]: https://github.com/rockorager/libvaxis/blob/main/src/Vaxis.zig
[vaxis-ctlseqs]: https://github.com/rockorager/libvaxis/blob/main/src/ctlseqs.zig
[vaxis-parser]: https://github.com/rockorager/libvaxis/blob/main/src/Parser.zig
[vaxis-loop]: https://github.com/rockorager/libvaxis/blob/main/src/Loop.zig
[vaxis-tty]: https://github.com/rockorager/libvaxis/blob/main/src/tty.zig
[termwiz-mod]: https://github.com/wezterm/wezterm/blob/main/termwiz/src/caps/mod.rs
[termwiz-probed]: https://github.com/wezterm/wezterm/blob/main/termwiz/src/caps/probed.rs
[wezterm-config]: https://github.com/wezterm/wezterm/blob/main/config/src/config.rs
[wezterm-termstate]: https://github.com/wezterm/wezterm/blob/main/term/src/terminalstate/mod.rs
[textual]: https://github.com/Textualize/textual
[textual-linux-driver]: https://github.com/Textualize/textual/blob/main/src/textual/drivers/linux_driver.py
[textual-parser]: https://github.com/Textualize/textual/blob/main/src/textual/_xterm_parser.py
[textual-app]: https://github.com/Textualize/textual/blob/main/src/textual/app.py
[superset-4041]: https://github.com/superset-sh/superset/issues/4041
[tcell-tscreen]: https://github.com/gdamore/tcell/blob/v2/tscreen.go
[tcell-vt]: https://github.com/gdamore/tcell/blob/main/vt/vt.go
[tcell-mock]: https://github.com/gdamore/tcell/blob/main/vt/mock.go
[tcell-sim]: https://github.com/gdamore/tcell/blob/v2/simulation.go
[vty-terminfo-based]: https://github.com/jtdaugherty/vty-unix/blob/main/src/Graphics/Vty/Platform/Unix/Output/TerminfoBased.hs
[vty-xtermcolor]: https://github.com/jtdaugherty/vty-unix/blob/main/src/Graphics/Vty/Platform/Unix/Output/XTermColor.hs
[vty-color]: https://github.com/jtdaugherty/vty-unix/blob/main/src/Graphics/Vty/Platform/Unix/Output/Color.hs
[crossterm-unix]: https://github.com/crossterm-rs/crossterm/blob/master/src/terminal/sys/unix.rs
[crossterm-style]: https://github.com/crossterm-rs/crossterm/blob/master/src/style.rs
[crossterm-ansi-support]: https://github.com/crossterm-rs/crossterm/blob/master/src/ansi_support.rs
[broot-ctx]: https://github.com/Canop/broot/blob/main/src/app/app_context.rs
[terminal-light]: https://github.com/Canop/terminal-light
[notty-mli]: https://github.com/pqwy/notty/blob/master/src/notty.mli
[notty-unix]: https://github.com/pqwy/notty/blob/master/src-unix/notty_unix.ml
[mosaic-query]: https://github.com/JakeWharton/mosaic/blob/trunk/mosaic-tty-terminal/src/commonMain/kotlin/com/jakewharton/mosaic/tty/terminal/TtyTerminal.kt
[mosaic-testterminal]: https://github.com/JakeWharton/mosaic/blob/trunk/mosaic-testing/src/commonMain/kotlin/com/jakewharton/mosaic/testing/TestTerminal.kt
