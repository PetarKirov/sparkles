# Spec: `sparkles.core_cli.term_caps` — terminal capability detection

**Status:** proposed (green-field redesign) · **Date:** 2026-07-13 · **Scope:**
the `sparkles.core_cli.term_caps` module (which this spec grows into the package
of §3) plus its `sparkles:base` seams
([`term_color`](../../../../libs/base/src/sparkles/base/term_color.d),
[`term_control`](../../../../libs/base/src/sparkles/base/term_control.d),
[`text/ansi`](../../../../libs/base/src/sparkles/base/text/ansi.d)).

_Audience: developers and coding agents building the module and its consumers.
Normative at the contract level — it states what the layer provides, not why. The
why lives in the evidence base: the
[terminal capability detection case study](../../../research/tui-libraries/capability-detection-case-study.md)
(its §15 design principles are the direct inputs here, cited as **CS-1** … **CS-15**)
and the co-located
[query probe](../../../research/tui-libraries/examples/query-probe.d), whose
13-terminal empirical matrix (case study §16) is this spec's fixture corpus. This
spec supersedes the `term_caps.d` design in
[tui-components §3](../tui-components/index.md) and retires that spec's §F
deferral ("`term_caps` stays env + ioctl until an interactive component forces
it") — the research that deferral waited on is done. The existing implementation
in
[`term_caps.d`](../../../../libs/core-cli/src/sparkles/core_cli/term_caps.d) is
disregarded except where a contract is explicitly carried over; pre-1.0 with all
consumers in-repo, there are no deprecation shims._

Sections marked **(target — Mn)** name a §17 milestone beyond the initial
delivery; everything unmarked is in scope for M1–M5.

## 1. Overview and invariants

The truth about the attached terminal is distributed across the process
environment (cheap, hearsay), an on-disk database (stale, keyed on a
self-reported name), and the terminal itself (authoritative, reachable only by a
write-then-read protocol). This module implements the pipeline every mature
detector converged on (**CS-1**): each layer is a separate, individually usable
API surface, and later layers refine while earlier layers veto.

| Layer  | Mechanism                                 | API surface (§)                                               | When it runs                         |
| ------ | ----------------------------------------- | ------------------------------------------------------------- | ------------------------------------ |
| **L0** | `isatty`, `TIOCGWINSZ`, `GetConsoleMode`  | `isTerminal`, `terminalSize`, `StreamInfo.probe` (§5)         | every snapshot                       |
| **L1** | environment variables                     | `EnvSnapshot` + pure classifiers → `detectTermCaps` (§6, §7)  | the default path — every CLI, always |
| **L2** | terminfo / termcap                        | **none — permanently out of scope** (§16, **CS-2**)           | never                                |
| **L3** | runtime interrogation                     | `interrogate` + `parseQueryReplies` + `refined` (§8, §9, §10) | opt-in, interactive programs         |
| **L4** | subscription modes (2048, 2031), SIGWINCH | event seam (§11)                                              | target — M6                          |

Three invariants bind every section below:

1. **Consent is law, and disable beats force.** `NO_COLOR` (parsed exactly:
   present-and-non-empty, never a boolean parse), `CLICOLOR`/`CLICOLOR_FORCE`,
   `FORCE_COLOR`, and explicit application overrides gate _emission_; no deeper
   layer — not terminfo, not the terminal's own answers — may override them.
   Consent never mutates the classified _capability_ tier (**CS-8**; the
   `term_color` split is kept).
2. **Detection is a pure function of explicit data; IO lives in thin shells.**
   `(EnvSnapshot, StreamInfo, Overrides) → TermCaps` and
   `reply bytes → QueryReport` are pure, `@safe`, CTFE-able where possible, and
   never read a global (**CS-5**, **CS-14**). The IO shells —
   `EnvSnapshot.fromProcess`, `StreamInfo.probe`, `TtySession` — only gather
   inputs. This is what lets the empirical matrix double as a fixture corpus
   (§14).
3. **Every fact carries provenance; absence is recorded, never fabricated.**
   Each capability field is a `Detected!T` that knows which layer produced it
   (**CS-4**). An unanswered query leaves the conservative default with
   `Provenance.defaulted` — a `bool` alone cannot say "nobody ever set me".
   Interrogation is fenced, deadlined, and drained (**CS-6**); it degrades to
   the env snapshot, and never hangs, throws, or blocks unbounded.

## 2. Decision ledger

| Area          | Decision                                                                                                                                                                                                                 |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Layer model   | L0 gates → L1 consents + guesses → L3 refines → L4 subscribes; **no terminfo, ever** — hardcoded sequences (`term_control`) + `XTGETTCAP` cover the residual terminfo-shaped facts (**CS-1**, **CS-2**)                  |
| Data model    | `TermCaps` stays a plain copyable/comparable value (**CS-3**) of enums + bools + `Detected!T` provenance wrappers; identity strings and raw evidence live in `QueryReport`, never in the snapshot                        |
| Degradation   | Monotone ladders, not booleans (**CS-9**): `ColorDepth` (existing), `GraphicsTier`, `KeyboardTier`; DEC-mode state kept as raw `ModeState` (the recognized-but-reset distinction is a capability signal)                 |
| Interrogation | Opt-in and tty-gated (**CS-7**): one batched write ending in a `DA1` fence, explicit deadline (default 1 s), post-fence quiet drain (**CS-6**); `/dev/tty` preferred, foreground-gated, raw mode restored idempotently   |
| Quirks        | Capability queries over identity queries; unavoidable quirks are a small data table keyed on already-collected env identity, applied _before_ sending (**CS-13**; today exactly one entry: `Apple_Terminal` query bleed) |
| Multiplexers  | Detected and recorded in the snapshot; their answers are believed _as the mux's_ (**CS-10**); passthrough envelopes are out of scope (§16)                                                                               |
| Windows       | Same seam, different verbs (**CS-11**): try-`SetConsoleMode` is the capability query; `prepareConsole` is split out as the one explicitly side-effecting call; VT interrogation over ConPTY is target-only               |
| Subscriptions | Snapshot + event seam, not snapshot-only (**CS-12**): modes 2048/2031 and the kitty flag stack deliver capability _changes_; the pure reply parser is reusable incrementally by an input loop (target — M6)              |
| Testability   | Detection over injected data; the §16 matrix rows replay through the pure parser as `@safe pure` unittests (**CS-14**); the research probe graduates into a thin front-end over this library (**CS-15**)                 |
| Errors        | `Expected!(T, QueryError)` per the repo idiom — interrogation failure is a value, not an exception; the convenience path degrades silently to the env snapshot                                                           |

## 3. Package and module layout

`sparkles.core_cli.term_caps` becomes a package;
`import sparkles.core_cli.term_caps;` keeps working via `package.d` re-exports.
Tests live in the feature modules, never in `package.d`.

| Module                    | Role                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `term_caps/package.d`     | `public import` re-exports only                                                                              |
| `term_caps/model.d`       | `TermCaps`, `Detected!T`, `Provenance`, `GraphicsTier`, `KeyboardTier`, `ModeState(s)`, `Rgb16`, `MuxKind`   |
| `term_caps/env.d`         | `EnvSnapshot`, `Overrides`, consent resolution, advertisement/mux/CI/locale classifiers (all pure)           |
| `term_caps/stream.d`      | `StdStream`, `isTerminal`, `terminalSize`, `StreamInfo`, `prepareConsole`, the SIGWINCH handler (L0)         |
| `term_caps/query.d`       | `QuerySet`, `writeQueryBatch`, `parseQueryReplies`, `QueryReport`, `refined`, reply-shape classifiers (pure) |
| `term_caps/interrogate.d` | `TtySession` raw-tty transport, `interrogate`, `interrogateTermCaps`, `QueryError` (the L3 IO shell)         |
| `term_caps/inspect.d`     | `dumpTermCaps` / `dumpQueryReport` provenance-annotated reports (the inspector, **CS-15**)                   |

Seams outside the package: `classifyColorDepth`/`ColorDepth` stay in
`sparkles.base.term_color` (already pure/CTFE-able); query bytes are spelled via
`sparkles.base.term_control` (`DecMode`, CSI plumbing); reply tokenization reuses
`sparkles.base.text.ansi.byAnsiToken`. The pure halves of `query.d` have no
`core_cli` dependencies by construction and may move to `base` if a second
out-of-package consumer ever appears — not before.

## 4. The capability value

```d
/// Which layer produced a capability fact. Not a precedence rank — precedence
/// is per-field policy (§7, §10); this records what actually happened.
enum Provenance : ubyte
{
    defaulted,    /// nobody set it: the type's conservative default
    os,           /// a stream/OS syscall (isatty, TIOCGWINSZ, GetConsoleMode)
    environment,  /// classified from environment variables
    query,        /// the terminal's own reply (L3)
    event,        /// updated by a later subscription report (L4)
    userOverride, /// explicit application/user override — never touched by refinement
}

/// A capability fact plus its provenance. `alias value this` keeps reads
/// ergonomic: `if (caps.colors)`, `caps.colorDepth >= ColorDepth.ansi256`.
struct Detected(T)
{
    T value;
    Provenance source;
    alias value this;
}

enum MuxKind : ubyte { none, tmux, screen, zellij }

/// Graphics degradation ladder, monotone (CS-9).
enum GraphicsTier : ubyte { none, sixel, kitty }

/// Keyboard degradation ladder: legacy byte input < kitty progressive enhancement.
enum KeyboardTier : ubyte { legacy, kitty }

/// Raw DECRPM state per DEC mode; numeric values match the wire protocol.
/// `recognized`/`active` helpers derive the two common predicates.
enum ModeState : byte
{
    unknown = -1,       /// never asked, or no reply before the fence
    notRecognized = 0,
    set = 1,
    reset = 2,          /// recognized but currently reset — still a capability signal
    permanentlySet = 3,
    permanentlyReset = 4,
}

/// The five interrogated modes as named fields (a value type — no AA), plus
/// `opIndex(DecMode)` for generic access.
struct ModeStates
{
    ModeState bracketedPaste = ModeState.unknown; // 2004
    ModeState syncOutput     = ModeState.unknown; // 2026
    ModeState unicodeCore    = ModeState.unknown; // 2027
    ModeState colorScheme    = ModeState.unknown; // 2031
    ModeState inBandResize   = ModeState.unknown; // 2048
}

/// 16-bit-per-channel color, the OSC 10/11 reply resolution (X11 rgb: spec).
struct Rgb16 { ushort r, g, b; }
```

The snapshot itself:

```d
struct TermCaps
{
    StdStream stream;                    /// the stream this snapshot describes
    bool tty;                            /// L0: `stream` is attached to a terminal
    MuxKind mux;                         /// multiplexer detected — answers describe it, not the outer terminal
    bool ci;                             /// $CI set; recorded for consumers, never forces color (§6)
    Detected!(ScreenSize!ushort) size;   /// os (ioctl) → event (mode-2048 report); 0 = unknown axis
    Detected!bool colors;                /// the consent verdict: emit SGR at all
    Detected!ColorDepth colorDepth;      /// tier; `none` whenever `colors` is off
    Detected!bool unicode;               /// emit non-ASCII glyphs (locale heuristic; Windows: UTF-8 CP)
    Detected!bool hyperlinks;            /// OSC 8; defaults to true — "mostly harmless", no query exists
    Detected!GraphicsTier graphics;      /// none < sixel < kitty
    Detected!KeyboardTier keyboard;      /// legacy < kitty
    ModeStates modes;                    /// raw DECRPM answers; all-unknown until interrogated
    Detected!Rgb16 foreground;           /// OSC 10; meaningful only when source >= query
    Detected!Rgb16 background;           /// OSC 11; `isDark(caps.background)` for scheme decisions
}
```

Normative properties:

- `TermCaps` is `@safe pure nothrow @nogc`-constructible, copyable, and
  equality-comparable — **no strings, no indirection**. Everything
  string-shaped a query returns (XTVERSION, DA2 identity, raw payloads) is
  evidence, not policy, and lives in `QueryReport` (§9). Consumers thread the
  snapshot through renderers as a plain argument; there is no module-level
  cached instance (**CS-3**).
- Existing consumer reads keep compiling: `caps.tty`, `caps.colors`,
  `caps.colorDepth`, `caps.unicode`, `caps.size` resolve through
  `Detected`'s `alias this`.
- `unicode` means "emit non-ASCII glyphs" (box drawing, `✓`/`✗`). Mode 2027
  state is a _width-semantics_ fact and is deliberately **not** folded into it
  — it is exposed raw as `modes.unicodeCore` for the future TUI layer
  ([`docs/specs/tui`](../../tui/index.md)) to build width policy on.
- Free helpers in `model.d`, all pure: `bool recognized(ModeState)`,
  `bool active(ModeState)` (set or permanently set), `bool isDark(Rgb16)`
  (relative-luminance threshold).

## 5. Layer L0: stream introspection

Carried over from the current module with contracts intact (they predate this
redesign and are already correct):

- `enum StdStream { stdin, stdout, stderr }`.
- `bool isTerminal(StdStream) @safe nothrow @nogc` — `isatty` on POSIX;
  `GetConsoleMode` success on Windows.
- `ScreenSize!ushort terminalSize(StdStream = stdout) @safe nothrow @nogc` —
  `TIOCGWINSZ` / `GetConsoleScreenBufferInfo`; a `0` component means "unknown on
  that axis"; streams may point at different terminals (`stderr` progress line
  vs redirected `stdout`).
- `setTermWindowSizeHandler` (POSIX SIGWINCH). Target redesign _(target — M6)_:
  the handler only stores the size atomically and consumers poll — and once
  mode 2048 is active the in-band reports supersede the signal entirely
  (case study §6: the first 2048 report both proves support and retires
  SIGWINCH).

New in this spec:

```d
/// Everything L0 knows about one stream, gathered in one probe — the pure
/// pipeline's second input.
struct StreamInfo
{
    StdStream stream;
    bool tty;
    bool vtEnabled;           /// POSIX: == tty; Windows: VT processing bit is on
    ScreenSize!ushort size;

    static StreamInfo probe(StdStream stream = StdStream.stdout) @safe nothrow @nogc;
}

/// The one explicitly side-effecting call, split out of detection (Sean Parent:
/// a "detect" function must not mutate). Windows: sets the output code page to
/// UTF-8 and try-enables ENABLE_VIRTUAL_TERMINAL_PROCESSING — Microsoft's
/// documented detect-by-trying mechanism (CS-11). POSIX: no-op. Idempotent.
void prepareConsole() @safe nothrow @nogc;
```

`StreamInfo.probe` **reads** console state (is the VT bit already on?); it never
sets it. Applications call `prepareConsole()` once at startup (the convenience
entry points in §7 and §8 do it for them).

## 6. Layer L1: the environment snapshot and its classifiers

```d
/// The complete environment evidence, captured once. Fields keep the raw
/// values (`null` = unset, `""` = set-but-empty — the NO_COLOR spec
/// distinguishes them); all interpretation happens in the pure classifiers.
struct EnvSnapshot
{
    string term, colorterm, termProgram, termProgramVersion;
    string noColor, clicolor, clicolorForce, forceColor;
    string tmux, sty, zellij, sshTty, ci;
    string lcAll, lcCtype, lang;

    static EnvSnapshot fromProcess() @safe;   // the only env-reading function
}

/// Application-level overrides — the top of the precedence ladder
/// (flag > env > detection, CS-8). Applied with Provenance.userOverride;
/// refinement (§10) never touches overridden fields.
enum Toggle : ubyte { auto_, off, on }

struct Overrides
{
    Toggle colors;                                /// off = disable, on = force
    Toggle unicode;
    ColorDepth maxDepth = ColorDepth.trueColor;   /// cap the classified tier (--color=16-style)
}
```

### Consent resolution (normative)

`resolveColorConsent(in EnvSnapshot, in Overrides)` — pure — evaluates in this
order; the first matching rung wins, and **every disable rung outranks every
force rung**:

1. `Overrides.colors == off` → disabled; `== on` → forced
   (`Provenance.userOverride`).
2. Disable rungs (`Provenance.environment`): `NO_COLOR` present and non-empty
   (exact presence-not-value parse — `NO_COLOR=yes` **disables**; the
   colorprofile `ParseBool` deviation is the anti-pattern) · `FORCE_COLOR ==
"0"` · `CLICOLOR == "0"` · `TERM == "dumb"`.
3. Force rungs (`Provenance.environment`): `CLICOLOR_FORCE` non-empty and not
   `"0"` · `FORCE_COLOR` ∈ {`"1"`, `"2"`, `"3"`} — the level additionally sets
   a depth floor (`ansi16`/`ansi256`/`trueColor`), the one consent variable
   that carries a depth. Force means force: colors go on even when the stream
   is not a tty (CI logs are the use case).
4. Otherwise auto: colors iff `StreamInfo.vtEnabled` (which on POSIX is
   tty-ness, and on Windows folds in the VT try-enable).

### Advertisement and context classifiers (all pure)

- Color tier: `classifyColorDepth(colorterm, term)` — unchanged, in
  `sparkles.base.term_color`.
- `MuxKind classifyMux(in EnvSnapshot)` — `TMUX` → tmux, `STY` → screen,
  `ZELLIJ` → zellij, plus `TERM` prefixes (`screen*`, `tmux*`) as fallback.
  Recorded in the snapshot; it does **not** suppress interrogation (§8 —
  the mux's answers are true, about the mux).
- `bool classifyUnicode(lcAll, lcCtype, lang)` — first non-empty of
  `LC_ALL > LC_CTYPE > LANG` matched case-insensitively against
  `utf-8`/`utf8`; no locale at all defaults to `true` (carried over).
- CI: `ci` = `$CI` non-empty. **No per-provider capability table** — the
  whitelist treadmill is the documented failure mode of env-first detectors.
  Sparkles' posture is termenv's, made explicit: CI is a non-tty; color there
  is opt-in via `CLICOLOR_FORCE`/`FORCE_COLOR` (which rung 3 honors on
  non-ttys). The `ci` bit is recorded so consumers can make their own calls
  (e.g. prompts must not block in CI).

## 7. The snapshot pipeline

```d
/// The pure core: every input explicit, CTFE-able, fixture-testable.
TermCaps classifyTermCaps(
    in EnvSnapshot env,
    in StreamInfo stream,
    in Overrides overrides = Overrides.init) @safe pure nothrow @nogc;

/// The everyday convenience: prepareConsole(), then classify over live inputs.
/// L0 + L1 only — one getenv batch and two syscalls; safe to call from any CLI
/// at startup, piped or not. Per-stream: stdout and stderr get separate verdicts.
TermCaps detectTermCaps(
    in Overrides overrides = Overrides.init,
    StdStream stream = StdStream.stdout) @safe;
```

Field-by-field derivation (normative):

| Field                      | Rule                                                                                          | Provenance                               |
| -------------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `tty`                      | `stream.tty`                                                                                  | (plain bool — L0 by definition)          |
| `mux`                      | `classifyMux(env)`                                                                            | (plain enum)                             |
| `ci`                       | `env.ci` non-empty                                                                            | (plain bool)                             |
| `size`                     | `stream.size`                                                                                 | `os`                                     |
| `colors`                   | consent verdict: disabled → `false`; forced → `true`; auto → `stream.vtEnabled`               | verdict's provenance; `os` on auto       |
| `colorDepth`               | `colors` off → `none`; else `max(classifyColorDepth(env), force floor)` clamped to `maxDepth` | `environment` (`userOverride` if capped) |
| `unicode`                  | `Overrides.unicode`, else locale heuristic (Windows: `true` after `prepareConsole`)           | `userOverride` / `environment` / `os`    |
| `hyperlinks`               | `true` — OSC 8 is ignored harmlessly by non-supporting terminals; no query exists             | `defaulted`                              |
| `graphics`                 | `GraphicsTier.none` — **never guessed from env**; only interrogation raises it                | `defaulted`                              |
| `keyboard`                 | `KeyboardTier.legacy` — same                                                                  | `defaulted`                              |
| `modes`                    | all `ModeState.unknown`                                                                       | —                                        |
| `foreground`, `background` | `Rgb16.init`                                                                                  | `defaulted`                              |

The `defaulted` rows are the point of the provenance design: an env-only
snapshot honestly reports that it knows nothing about graphics, keyboard, or
modes, instead of encoding "no" (case study §2: color is the only class L1 can
detect — env-only detectors must not pretend otherwise).

## 8. Layer L3: interrogation

Interrogation is a separate, explicit call — never implicit in
`detectTermCaps` (**CS-7**; the bubbletea v1 import-time hang is the documented
cost of implicitness).

### Transport: `TtySession`

```d
enum QueryError : ubyte
{
    notATerminal,   /// no controlling terminal / stdin+stdout not a tty
    dumbTerminal,   /// TERM=dumb — by convention, do not query
    notForeground,  /// process is not in the tty's foreground process group
    rawModeFailed,  /// tcgetattr/tcsetattr failed
    ioError,        /// write failed mid-battery
    unsupported,    /// platform has no interrogation path (Windows, pre-M6)
}

/// RAII raw-mode session over the controlling terminal. Non-copyable.
struct TtySession
{
    static Expected!(TtySession, QueryError) open() @safe;
    void close();   // restores termios; idempotent; also run by the destructor
}
```

Normative transport rules:

- **Own the right descriptor:** open `/dev/tty` read-write; fall back to
  stdin/stdout only when it is unavailable and both are ttys (libvaxis
  precedent).
- **Foreground gate:** refuse (`notForeground`) when
  `tcgetpgrp(fd) != getpgrp()` — a backgrounded reader races the foreground
  job for the same input bytes (termenv precedent).
- **Raw mode:** clear `ECHO | ICANON | ISIG` with `TCSAFLUSH` (flushing stale
  typed-ahead input). `ISIG` deliberately: every read is deadline-bounded, so
  Ctrl+C is never needed to escape a hang — and keeping it would let Ctrl+C
  kill the process before the termios restore. Restore is idempotent and
  guaranteed on every exit path (`scope(exit)`/destructor).
- The raw-mode primitive is shared `package`-visible plumbing;
  [`key_input.d`](../../../../libs/core-cli/src/sparkles/core_cli/key_input.d)
  migrates onto it _(target — M6)_ instead of keeping a private copy.

### The battery

```d
/// Which query families to send. Defaults are the full standard battery;
/// forEnv() applies the pre-send quirk table (CS-13).
struct QuerySet
{
    bool identity      = true;  // XTVERSION + DA2
    bool modes         = true;  // DECRQM × {2004, 2026, 2027, 2031, 2048}
    bool tcaps         = true;  // XTGETTCAP RGB / Tc / Su
    bool oscColors     = true;  // OSC 10 / OSC 11
    bool kittyKeyboard = true;  // CSI ? u
    bool kittyGraphics = true;  // APC G … a=q

    static QuerySet standard() @safe pure nothrow @nogc;
    static QuerySet forEnv(in EnvSnapshot env) @safe pure nothrow @nogc;
}

/// Pure battery emission — writer idiom, @nogc; the DA1 fence is always
/// appended last, regardless of the set.
void writeQueryBatch(Writer)(ref Writer w, in QuerySet q);
```

The battery, in send order (empirically validated across the matrix's 13
terminals — this is the probe's exact order):

| #     | Query                      | Bytes                                     | Gate            |
| ----- | -------------------------- | ----------------------------------------- | --------------- |
| 1     | XTVERSION                  | `CSI > 0 q`                               | `identity`      |
| 2     | kitty keyboard flags       | `CSI ? u`                                 | `kittyKeyboard` |
| 3–7   | DECRQM, one per mode       | `CSI ? Pn $ p`                            | `modes`         |
| 8–10  | XTGETTCAP, one per cap     | `DCS + q <hex(cap)> ST`                   | `tcaps`         |
| 11–12 | OSC 10 / OSC 11            | `OSC 10 ; ? BEL` / `OSC 11 ; ? BEL`       | `oscColors`     |
| 13    | kitty graphics round-trip  | `APC G i=31,s=1,v=1,a=q,t=d,f=24;AAAA ST` | `kittyGraphics` |
| 14    | secondary DA               | `CSI > c`                                 | `identity`      |
| 15    | **primary DA — the fence** | `CSI c`                                   | always          |

**Quirk table** (`QuerySet.forEnv`): under `TERM_PROGRAM=Apple_Terminal`, only
`identity` and `oscColors` survive — the matrix captured Terminal.app printing
five literal `p`s plus the XTGETTCAP/APC payloads at the prompt (case study
§16). Quirks are pre-send data keyed on env identity, never a runtime
heuristic; the table is expected to stay near length one.

### The protocol

```d
Expected!(QueryReport, QueryError) interrogate(
    scope ref TtySession tty,
    in QuerySet queries = QuerySet.standard,
    Duration deadline = 1.seconds);
```

1. Write the whole battery in **one flush**. Terminals answer in order, so the
   trailing DA1 reply proves every earlier query has answered or never will
   (**CS-6**; "all known terminals respond to DA1").
2. Read under the deadline until a _complete_ `CSI ? … c` token arrives
   (completeness matters — an unterminated trailing escape is not the fence).
   Real terminals answer the full battery in 1–20 ms (matrix measurement); the
   deadline is insurance for the no-emulator case (bare PTY, serial line), and
   1 s matches the vaxis/mosaic/probe convention. It is a parameter, not a
   constant.
3. **Quiet-drain** after the fence (or the deadline): keep reading until ~25 ms
   of silence, so no straggler reply outlives the session and leaks into the
   parent shell as typed garbage — whoever writes a query owns its reply's
   entire lifetime (case study §12).
4. Non-escape bytes read during the window (interleaved keystrokes) are
   discarded and counted in `QueryReport.strayTokens`. This is the documented
   cost of a one-shot startup probe; the L4 seam (§11) is the design for
   programs that cannot accept it.

The report's payload fields are slices into a transcript buffer owned by the
session (`return scope`-checked under dip1000): extract with `refined` — which
copies only enums and bools — before closing the session, or dup explicitly.

### The convenience path

```d
/// detectTermCaps ∘ interrogate ∘ refined in one call for interactive apps:
/// snapshot the environment, open a session, send QuerySet.forEnv(env), fold
/// the report in. Any QueryError degrades silently to the env-only snapshot —
/// interrogation failing is normal (piped, CI, dumb, backgrounded), not an error.
TermCaps interrogateTermCaps(
    in Overrides overrides = Overrides.init,
    StdStream stream = StdStream.stdout,
    Duration deadline = 1.seconds) @safe;
```

## 9. Reply parsing (pure)

```d
/// Pure classification of accumulated reply bytes. Tokenization is
/// byAnsiToken's escape grammar; dispatch is by (introducer, prefix, final
/// byte) — every reply shape in the battery is unambiguous. `sent` supplies
/// query order for the one stateful case (XTGETTCAP failure replies that omit
/// the capability name are attributed FIFO).
QueryReport parseQueryReplies(
    return scope const(char)[] transcript,
    in QuerySet sent) @safe pure nothrow @nogc;
```

| Reply shape (introducer · prefix · final) | Classified as                                          |
| ----------------------------------------- | ------------------------------------------------------ |
| `DCS > \| … ST`                           | XTVERSION name/version                                 |
| `DCS 1 + r key=val ST` / `DCS 0 + r … ST` | XTGETTCAP valid / invalid (hex key; FIFO when keyless) |
| `OSC 10 ; rgb:… BEL-or-ST`                | foreground color                                       |
| `OSC 11 ; rgb:… BEL-or-ST`                | background color                                       |
| `APC G … ST`                              | kitty graphics reply (`;OK` = supported)               |
| `CSI ? Pn ; Ps $ y`                       | DECRPM → `ModeStates` field for mode `Pn`              |
| `CSI ? flags u`                           | kitty keyboard flags                                   |
| `CSI > Pp ; Pv ; Pc c`                    | secondary DA identity                                  |
| `CSI ? Ps ; … c`                          | **primary DA — the fence**; attribute list retained    |
| anything else escape-shaped               | counted unrecognized                                   |
| plain text tokens                         | counted stray (interleaved keystrokes)                 |

```d
enum TcapStatus : ubyte { noReply, valid, invalid }

struct QueryReport
{
    bool fenced;                     /// the DA1 reply arrived before the deadline
    Duration elapsed;                /// time to fence (or the full deadline) — filled by interrogate()
    const(char)[] da1;               /// raw attribute payload, e.g. "62;22;52"; null = no reply
    const(char)[] da2;               /// identity payload — informational only, never keys policy
    const(char)[] xtversion;         /// e.g. "ghostty 1.3.1" — informational only
    const(char)[] kittyKbdFlags;     /// raw flags digits; non-null = protocol supported
    ModeStates modes;
    TcapStatus rgb, tc, su;
    bool fgAnswered, bgAnswered;
    Rgb16 foreground, background;
    bool gfxOk;                      /// kitty graphics round-trip succeeded
    int strayTokens;
    int unrecognized;
}
```

Supporting pure classifiers (each individually unit-tested, CTFE-able):

- `ModeState classifyDecrpm(int value)` — the wire value maps 1:1 (§4).
- `bool da1AdvertisesSixel(const(char)[] payload)` — attribute list contains
  `4` (matrix: iTerm2 `64;1;2;4;…`, WezTerm `65;4;…`).
- `bool parseX11Color(const(char)[] payload, out Rgb16)` — the
  `rgb:RRRR/GGGG/BBBB` family, scaling 1–4 hex digits per channel to 16 bits.

Identity answers (`da2`, `xtversion`) are **retained but never used for
capability decisions** (**CS-13**): DA2 is mimicked to the point of uselessness
(the case study's VTE/Alacritty/tmux evidence). They exist for the inspector,
bug reports, and the quirk table's key space.

## 10. Refinement: folding a report into the snapshot

```d
/// Pure merge. Only upgrades: query evidence raises ladders, never lowers a
/// verdict below the env classification; fields with Provenance.userOverride
/// are never touched; consent is never revisited (CS-8).
TermCaps refined(TermCaps base, in QueryReport report) @safe pure nothrow @nogc;
```

Normative rules, per field:

| Field                       | Upgrade rule                                                                                               |
| --------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `colorDepth`                | `rgb == valid \|\| tc == valid` → raise to `trueColor` (clamped to `Overrides.maxDepth`; only if `colors`) |
| `graphics`                  | `gfxOk` → `kitty`; else `da1AdvertisesSixel(report.da1)` → `sixel`                                         |
| `keyboard`                  | `kittyKbdFlags` non-null → `kitty`                                                                         |
| `modes`                     | copied verbatim (raw evidence — consumers apply their own policy over `ModeState`)                         |
| `foreground` / `background` | copied when answered                                                                                       |
| everything else             | unchanged — `colors`, `unicode`, `size`, `tty`, `mux`, `ci`, `hyperlinks` have no L3 producer              |

Every field a rule touches gets `Provenance.query`. The upgrade-only discipline
is bubbletea v2's runtime-upgrade model made total: env guesses a floor,
answers raise it, and nothing an unanswering terminal fails to say can make the
program _less_ capable than the environment already justified.

## 11. Layer L4: the subscription seam (target — M6)

Modes 2048 (in-band resize) and 2031 (color-scheme reports), the kitty flag
stack, and SIGWINCH deliver capability _changes after detection completes_; a
one-shot struct cannot represent them (**CS-12**). The seam, not a full event
loop, is in scope here:

- `parseQueryReplies` is reusable **incrementally**: the future input loop
  (the [`sparkles:tui` spec](../../tui/index.md)'s event layer, or `prompts`'
  raw-mode reader) feeds it whole tokens from its own stream and receives
  classified capability events instead of running a second parser.
- DbI shell-with-hooks dispatch: the reply dispatcher checks
  `static if (is(typeof(hooks.onResize)))` / `onColorScheme` /
  `onModeReport` and forwards parsed payloads; a `TermCaps` field updated
  this way carries `Provenance.event`.
- Contracts to encode when this lands: enabling 2048 **is** the query (the
  first report proves support, delivers the size, and retires SIGWINCH);
  2031 pairs a subscription with the one-shot `CSI ? 996 n` preference query.

Until M6, interactive consumers use the snapshot plus SIGWINCH exactly as
today.

## 12. Windows (target — M6)

Same seam, different verbs (**CS-11**). Shipped in M1–M5: `prepareConsole`'s
try-`SetConsoleMode` (the official detect-by-trying mechanism) feeding
`StreamInfo.vtEnabled`, UTF-8 code page, and the env pipeline unchanged —
`TtySession.open` returns `QueryError.unsupported`. Target: a console-input
transport for the same battery (ConPTY answers real VT queries; legacy conhost
answers nothing — the deadline already covers both), keeping every pure layer
byte-identical. No `WT_SESSION` sniffing (broken in both directions per the
case study), no OS-build capability tables.

## 13. The inspector

Detection bugs are environmental; the fix starts from a report of _what was
asked, what answered, and what was concluded_ (**CS-15**).

```d
void dumpTermCaps(Writer)(ref Writer w, in TermCaps caps);        // value + provenance per field
void dumpQueryReport(Writer)(ref Writer w, in QueryReport report); // sent / raw reply / classification per query
```

The research probe
([`query-probe.d`](../../../research/tui-libraries/examples/query-probe.d))
graduates into a thin front-end over the library (M5): its battery builder,
raw-mode session, collector, and classifier are replaced by `writeQueryBatch`,
`TtySession`, `interrogate`, and `parseQueryReplies`; it keeps its CLI, the
`--markdown` matrix-row emitter, and `--raw`. The probe run inside a terminal
then _is_ the library's end-to-end empirical test — and new matrix rows keep
feeding §14's corpus.

## 14. Testing contract

- **Classifiers and parser are the test surface.** Consent resolution, mux/
  locale/CI classification, `classifyDecrpm`, `da1AdvertisesSixel`,
  `parseX11Color`, `parseQueryReplies`, `classifyTermCaps`, and `refined` are
  all pure over explicit inputs: `@safe pure` unittests (with `nothrow @nogc`
  where the signatures promise it), CTFE `static assert` for at least the
  consent table and the color classifiers.
- **The empirical matrix is the fixture corpus** (**CS-14**). Each §16 matrix
  row is reconstructed as a transcript string literal and replayed through
  `parseQueryReplies` + `refined`, asserting the classified outcome, e.g.:

  ```d
  @("termCaps.parse.ghostty131")
  @safe pure nothrow @nogc
  unittest
  {
      enum transcript = "\x1bP>|ghostty 1.3.1\x1b\\" ~ "\x1b[?0u"
          ~ "\x1b[?2004;2$y" ~ "\x1b[?2026;2$y" ~ "\x1b[?2027;1$y"
          ~ "\x1b[?2031;2$y" ~ "\x1b[?2048;2$y"
          // … XTGETTCAP, OSC 10/11, APC OK, DA2 …
          ~ "\x1b[?62;22;52c";
      const report = parseQueryReplies(transcript, QuerySet.standard);
      assert(report.fenced && report.tc == TcapStatus.valid);
      assert(report.modes.unicodeCore == ModeState.set);
  }
  ```

  Required rows at minimum: ghostty, kitty (rejects `RGB`, accepts `Tc`/`Su` —
  the vocabulary split), iTerm2 (sixel in DA1, 2027 = 4), XTerm, Alacritty
  (bare `6` DA1), WezTerm (2027 = 3), tmux-detached, GNU screen 4 (the floor),
  Apple Terminal, and the empty transcript (bare PTY — nothing fenced,
  everything defaulted).

- **Consent matrix test:** table-driven over
  `{NO_COLOR, CLICOLOR, CLICOLOR_FORCE, FORCE_COLOR, TERM} × {tty, pipe} ×
Overrides`, pinning every rung and the disable-beats-force law.
- **No test requires a tty.** `dub test` runs piped; `TtySession.open` under
  the harness must return `notATerminal`, and exactly that path is the
  environment-dependent contract test (no `skipTest` needed — the outcome is
  deterministic under the harness).
- Round-trip: `writeQueryBatch` output for `QuerySet.standard` is
  byte-pinned against the probe's shipped battery (§8's table is normative).

## 15. Consumers and migration

| Consumer                                        | Change                                                                                                                                                   |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test-runner-impl` (`runner_impl.d`, reporting) | `detectTermCaps(noColors)` call site becomes `detectTermCaps(Overrides(colors: noColours ? Toggle.off : Toggle.auto_))`; reads unchanged                 |
| `release` / `ci`                                | same mechanical override migration; both gain `caps.ci` for prompt gating                                                                                |
| `prompts` / `key_input`                         | tty gates unchanged; `key_input` adopts the shared raw-mode primitive _(target — M6)_                                                                    |
| `ui/live`, `ui/tasklist`                        | non-TTY policy keeps keying off `caps.tty`/`caps.colors`; may additionally consult `modes.syncOutput` after interrogation instead of emitting 2026 blind |
| `sparkles.syntax.color.detectColorDepth`        | unchanged (its own thin env wrapper over the base classifier); may later delegate to `classifyTermCaps`                                                  |
| future `sparkles:tui`                           | the interactive consumer interrogation was deferred for: `interrogateTermCaps` at startup, the §11 event seam for the loop                               |
| research probe                                  | becomes a front-end over the library (§13)                                                                                                               |

Breaking changes are expected and unshimmed; the only stable contracts are the
L0 functions (§5) and the `TermCaps` field-read spellings noted in §4.

## 16. Out of scope

- **terminfo/termcap, permanently** (**CS-2**): no database read, no `infocmp`
  shell-out, no compiled-in entries. `XTGETTCAP` asks the terminal itself for
  the residual terminfo-shaped facts.
- **tmux passthrough envelopes** (`DCS tmux; … ST`): reaching the _outer_
  terminal is a separate, explicitly-requested feature with its own reordering
  hazards; the seam is acknowledged (**CS-10**), not built.
- **DA3 / XTWINOPS pixel geometry / OSC 52 / OSC 4 palette dumps**: no
  consumer; add to the battery only with one.
- **Kitty text-sizing cursor-movement probes** (the width oracle): the right
  tool for width-method detection, owned by the future TUI width policy, not
  by this module's battery.
- **CI-provider capability tables, terminal-name whitelists, OS-build-number
  oracles**: the maintenance treadmill every surveyed env-first detector is
  stuck on; deliberately refused.
- **A general input/event framework**: §11 is a seam for one, not one.

## 17. Delivery milestones

| Milestone | Contents                                                                                                                          |
| --------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **M1**    | `model.d` + `env.d`: the value types, classifiers, consent resolution, `classifyTermCaps` — pure core, CTFE tests, consent matrix |
| **M2**    | `stream.d` + package split: L0 port, `StreamInfo.probe`, `prepareConsole` split, `detectTermCaps` v2; consumers migrated (§15)    |
| **M3**    | `query.d`: battery writer, pure parser, `refined`, the full §14 fixture corpus                                                    |
| **M4**    | `interrogate.d`: `TtySession`, `interrogate`, `interrogateTermCaps`; byte-pinned battery round-trip                               |
| **M5**    | `inspect.d`; probe migrated onto the library; `docs/libs/core-cli/` Diátaxis seed for the module                                  |
| **M6**    | _(targets)_ L4 event seam; shared raw-mode primitive under `key_input`; Windows VT interrogation; SIGWINCH store-only redesign    |

Each milestone lands green on its own (`dub test :core-cli`, `dub test :base`),
per the repo's atomic-commit policy.
