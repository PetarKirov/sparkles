# Racket `racket/draw` and `pict` — measurement on the device, extent on the scene

**Category:** device abstraction under an FP layer. **Last reviewed:** August 23, 2026.
Pinned at [`c2f36f53`][rev-draw] (`racket/draw`) and [`f96ef6a7`][rev-pict] (`racket/pict`).

Two layers, surveyed together because neither is legible alone. `racket/draw`
is a 72-member device-context interface with bitmap, PostScript, SVG, PDF,
recording and printer implementations; `pict` is a purely functional image
algebra layered directly on top of it. The pair is the survey's clearest
**dissenter from [F1][comparison]** — Racket puts text measurement _on the
device context_ — and simultaneously its fullest confirmation of
[F7][comparison], because it ships all three extents the finding separates: the
device reports its drawing area, a `pict` carries a self-describing layout box,
and `record-dc%` reports the ink extent of a recorded scene.

|                      |                                                                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**         | Racket                                                                                                                                |
| **License**          | Apache-2.0 OR MIT ([`LICENSE`][license])                                                                                              |
| **Repository**       | [`racket/draw`][rev-draw], [`racket/pict`][rev-pict] (separate packages)                                                              |
| **Documentation**    | [`draw-doc/scribblings/draw/`][dc-doc], [`pict-doc/pict/scribblings/pict.scrbl`][pict-doc]                                            |
| **Category**         | device abstraction under an FP layer                                                                                                  |
| **Pinned revision**  | `c2f36f533ea6ee3f6400bf352d3d511dbf659916` / `f96ef6a7c26dbe38c1c8c958a9fd7e25bd521fbc`                                               |
| **Seam**             | `dc<%>` — a `racket/class` interface, 72 members, contracted                                                                          |
| **Backends shipped** | `bitmap-dc%`, `post-script-dc%`, `pdf-dc%`, `svg-dc%`, `record-dc%`; `printer-dc%` and canvas DCs live in [`racket/gui`][printer-doc] |
| **Implementation**   | Cairo + Pango behind every backend                                                                                                    |

## Overview

### What it solves

One drawing vocabulary for a screen canvas, an offscreen bitmap, a PostScript,
PDF or SVG file, and a printer — plus a recorder that replays into any of them.
The guide states the model plainly:

> The `racket/draw` library provides a drawing API that is based on the
> PostScript drawing model. It supports line drawing, shape filling, bitmap
> copying, alpha blending, and affine transformations (i.e., scale, rotation,
> and translation).
>
> — [`draw-doc/scribblings/draw/guide.scrbl`][guide]

That sentence predicts almost everything below. The seam's nouns are pens,
brushes, paths, fonts and transformations — a **document imaging model**, not a
widget model — which is why no scrollbar appears in it (Q3) and why appearance
is a device state machine rather than a per-command payload (Q6).

### Design philosophy

Racket is unusually honest about the leak. The guide's portability section:

> Drawing effects are not completely portable across platforms, across
> different classes that implement `dc<%>`, or different kinds of bitmaps.
> Fonts and text, especially, can vary across platforms and types of DC, but so
> can the precise set of pixels touched by drawing a line.
>
> — [`guide.scrbl`][guide]

Above that sits `pict`, whose philosophy is the opposite of a device's:

> The size information for a pict is computed when the pict is created. This
> strategy supports programs that create new picts though arbitrarily complex
> computations on the size and shape of existing picts.
>
> — [`pict.scrbl`][pict-doc]

Extent is **eagerly computed and stored in the value**. That is what makes the
combinator algebra pure arithmetic, and it is the reason a pict needs a device
only at its leaves.

## How it works

### The seam is an interface value, not a class hierarchy

`dc<%>` is defined once, as data, in [`dc-intf.rkt`][dc-intf-src]. Because
`racket/class` interfaces are first-class values and Racket contracts are
first-class too, the declaration carries a machine-checked signature per method:

```racket
(define dc<%>
  (interface ()
    [draw-text (->*m (string? real? real?)
                     (any/c exact-nonnegative-integer? real?)
                     void?)]
    [start-alpha (->m real? void?)
                 #:public (lambda (a) (void))]
    [get-size (->m (values (and/c real? (not/c negative?))
                           (and/c real? (not/c negative?))))]
    [get-text-extent (->*m (string?)
                           ((or/c (is-a?/c font%) #f) any/c exact-nonnegative-integer?)
                           (values (and/c real? (not/c negative?)) (and/c real? (not/c negative?))
                                   (and/c real? (not/c negative?)) (and/c real? (not/c negative?))))]
    ...))
```

Seventy-two members, of which fifteen are drawing operations; the rest are
state accessors, transformation control, document lifecycle and measurement.
Note `#:public` on `start-alpha`/`end-alpha`: a Racket interface may carry a
**default method body**, so a backend that cannot group-composite silently
inherits a no-op — Slint's default-trait-method device, inside a nominal
interface.

### There is a second, private seam underneath

The surveyed subject is really two seams. Everything public goes through
`dc<%>`; every backend is built by applying a shared `dc-mixin` to a
_backend object_ that implements the internal `dc-backend<%>`
([`dc.rkt`][dc-src]). That inner interface is where capability lives:

```racket
;; can-mask-bitmap? : -> bool
;; Return #t if bitmap drawing with a mask is supported.
;; It's not supported for PostScirpt output, for example.
can-mask-bitmap?

;; get-hairline-width
;; Gets the pen width to use in place of 0 in 'smoothed mode
get-hairline-width

;; method get-font-metrics-key : real real -> integer
;; Gets a font-merics key for the current scale. 0 is always a
;; safe result, but the default is to return 1 for an unscaled dc.
get-font-metrics-key
```

(`sic` on both typos, quoted verbatim from [`dc.rkt`][dc-src].) So the
capability booleans exist, they are per-device, and the **framework** — the one
shared `dc-mixin` — reads them and degrades once. The application never sees
them. That is the **framework** slot in [F4][comparison]'s list of six places a
lowering can live, with the query made private.

### `pict` is an algebra over four numbers

A pict is a struct whose field comments are its specification
([`pict.rkt`][pict-src]):

```racket
(define-struct in:pict (draw       ; drawing instructions
                        width      ; total width
                        height     ; total height >= ascent + desecnt
                        ascent     ; portion of height above top baseline
                        descent    ; portion of height below bottom baseline
                        children   ; list of child records
                        panbox     ; panorama box, computed on demand
                        last)      ; a descendent for the bottom-right
  #:reflection-name 'pict
  #:mutable
  ...)
```

`draw` is an S-expression command list interpreted by a private `render`
procedure against a `dc<%>`; the `dc` constructor makes "an arbitrary
self-rendering pict" ([`pict.scrbl`][pict-doc]) from a closure plus
author-declared `w h a d`. The eight `*-append` combinators and the fifteen
`*-superimpose` combinators are each generated from one parameterised factory
that does nothing but arithmetic on those four numbers plus a `child` transform
record. **No device is consulted during composition** — only at the `text` leaf.

## Q1 — measurement unit, and who answers

Racket is the survey's dissenter. `get-text-extent` is a **method on the
drawing context**, returning four device-space reals (width, height, descent,
extra vertical space) in whatever units that device uses. Measurement is
therefore not merely device-flavoured, it is device-_addressed_: you must hold
a DC to ask.

The design leans on an assumption it states out loud:

> The drawing context installed in this parameter need not be the same as the
> ultimate drawing context, but it should measure text in the same way. Under
> normal circumstances, font metrics are the same for all drawing contexts, so
> the default value of `dc-for-text-size` is a `bitmap-dc%` that draws to a
> 1-by-1 bitmap.
>
> — [`pict.scrbl`][pict-doc]

`dc-for-text-size` is a parameter whose default is literally
`(make-object bitmap-dc% (make-bitmap 1 1))` ([`pict.rkt`][pict-src]) — a real
Cairo surface allocated for no reason but to hold font metrics. `pict`'s `text`
constructor dereferences it and fails hard when it is `#f`, with
`(error 'text "no dc<%> object installed for sizing")`.

> [!IMPORTANT]
> The library contradicts its own reassurance. `get-font-metrics-key` returns a
> **device-class identity**, and the three concrete backends return three
> different constants for the unscaled case: `1` from the default backend
> ([`dc.rkt`][dc-src]), `2` from `post-script-dc%` ([`post-script-dc.rkt`][ps-src]),
> `3` from `svg-dc%` ([`svg-dc.rkt`][svg-src]), and `0` — "no key available" —
> whenever the DC is scaled. The public documentation says the key is "valid
> across all `dc<%>` instances, even among different classes"
> ([`dc-intf.scrbl`][dc-doc]), which is exactly what makes it a metric-universe
> tag: two DCs may share metrics **iff** they share a non-zero key. So
> `dc-for-text-size`'s bitmap default (key `1`) is provably the wrong measurer
> for a pict destined for PostScript (key `2`), and the library ships no
> mechanism that notices.

Everything downstream of a measurement is baked into immutable pict extents at
construction time, so a mis-chosen sizing DC yields a layout that is silently
wrong on the target and cannot be re-derived. **Racket does not refute
[F1][comparison]; it is the one priced dissent in it** — a global device
parameter, a wasted 1×1 surface, and an unenforced obligation to match metric
universes by hand. `sparkles:ui` puts `measure` on the painter too, and pays a
different bill for it: [friction §1][friction] is the same decision met from
the unit side rather than the addressing side.

One benefit is real: a caller that _does_ hold the target DC gets that device's
own shaping. `get-text-extent`'s `combine-mode` selects among "each character
separately", `'grapheme` clusters, and full ligature/kerning/bidi shaping
([`dc-intf.scrbl`][dc-doc]) — three measurement fidelities named by the caller,
resolved by the device.

## Q2 — is the contract stated in one place?

**Yes, and this is Racket's strongest result.** The whole contract is one
value, `dc<%>`, with a runtime-checked signature on every member; there is no
`__traits(compiles)` equivalent anywhere and nothing is discovered by probing.
Every backend implements all 72 members, totally.

The cost is that totality is a fiction maintained three different ways, and the
docs enumerate each:

| Mechanism                        | Example                                                                                                                                       | Where stated                                            |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| **Interface default body**       | `start-alpha`/`end-alpha` are `#:public (lambda (a) (void))`; "The `dc<%>` implementation has no effect"                                      | [`dc-intf.rkt`][dc-intf-src], [`dc-intf.scrbl`][dc-doc] |
| **Documented silent lossiness**  | "For `post-script-dc%` and `pdf-dc%` output, opacity from an alpha channel … is rounded to full transparency or opacity"                      | [`dc-intf.scrbl`][dc-doc]                               |
| **Silent no-op on bad state**    | a `bitmap-dc%` with no bitmap installed: "If any other `bitmap-dc%` method is called before a bitmap is selected, the method call is ignored" | [`bitmap-dc-class.scrbl`][bitmap-dc-doc]                |
| **Hard exception on bad state**  | "Attempts to use a drawing method outside of an active page raises an exception"                                                              | [`blurbs.rkt`][blurbs] (the shared `PrintNote`)         |
| **Private capability predicate** | `can-mask-bitmap?` returns `#f` for PostScript, and the framework degrades                                                                    | [`dc.rkt`][dc-src], [`post-script-dc.rkt`][ps-src]      |

Two of those are worth transplanting.

**The lifecycle discipline is mechanised, not documented.** `doc+page-check-mixin`
([`page-dc.rkt`][page-src]) wraps a backend with a three-state machine
(`#f` → `'doc` → `'page`) and a macro, `check-page-active`, listing **exactly
the fifteen methods that require an active page** — the thirteen `draw-*`,
plus `clear` and `erase`. That list is the seam's real drawing subset,
separated from its query/state subset in one place, machine-readable, applied
by mixing rather than by convention. `get-text-extent`, `get-char-width` and
`get-char-height` are deliberately outside it, and `bitmap-dc%` names the same
three as callable without a bitmap installed.

**Three real capability queries do exist on the public seam**, all of them
returning a value rather than requiring a probe: `ok?` (is this DC usable at
all), `get-gl-context` (returns `#f` when unsupported), and `glyph-exists?`
(per-character, and the docs note it is a property of the DC type, not of the
font passed in).

## Q3, Q6 — semantic operations and where appearance lives

**Neither.** The seam carries no semantic widget — no scrollbar, no focus ring,
no text input, no shadow — and no per-command appearance either. Appearance is
**device state**: `set-pen`, `set-brush`, `set-font`, `set-alpha`,
`set-smoothing`, `set-text-foreground`, `set-text-background`, `set-text-mode`,
`set-clipping-region`, plus the transformation stack. A `draw-rectangle` call
takes four reals and nothing else.

That is the PostScript model, and it is one of the cheaper encodings
[F9][comparison] counts: Slint carries the role in the method name, egui
resolves by tessellation, `sparkles:ui` stores the resolved fields each
primitive paints from and, on six of its eight payloads, a semantic `Slot`
beside them — Racket carries appearance **out of band entirely**, so the
marginal cost of an operation is zero fields.

The consequence shows up in `record-dc%`, which must save and restore the
target's entire state around a replay — pen, brush, font, smoothing, text mode,
background, text background, text foreground, alpha, clipping region, origin,
scale, rotation and initial matrix, enumerated one by one in
`generate-drawer/restore` ([`record-dc.rkt`][record-src]) — to honour the
documented invariant that "all settings in the target drawing context … are as
before the replay" ([`record-dc-class.scrbl`][record-doc]).

**Out-of-band appearance makes commands cheap and composition expensive.** For
`sparkles:ui`, whose display list is replayed into several backends and
compared op-by-op by `RecordingCanvas`, the transposed choice — resolved
appearance on the operation rather than on the device — is what keeps the
stream comparable without a state machine to unwind first. That prices
[friction §6][friction] rather than resolving it: the seam pays for the role
as well as the appearance, and the fact that a `Visual` is reconstructed
through `visualOf` rather than stored makes the hedge cheap, not decided.

## Q4 — command shape

`dc<%>` dispatches through methods; there is no reified command value in the
seam itself. But **`record-dc%` reifies the stream anyway, in two
representations at once**, and the technique is the most transferable thing in
this subject.

`record-dc-mixin` ([`record-dc.rkt`][record-src]) is generated by a
`define/record` macro that, for each recorded method, emits an override which
calls `super` and then stores **both** a replay closure and a serialisable
datum:

```racket
#'(define/override (name arg-formal ...)
    (begin0
     (super name arg-id ...)
     (when (continue-recording?)
       (let (arg-bind ...)
         (record (lambda (dc) (send dc name arg-id ...))
                 (lambda () (list 'name (arg-convert ... arg-id) ...)))))))
```

`get-recorded-procedure` returns the composed closure; `get-recorded-datum`
returns "a value that can be printed with `write` and re-read with `read`"
([`record-dc-class.scrbl`][record-doc]), reconstituted by `recorded-datum->procedure`.
The tag is the method's own name symbol and the payload is the argument list —
**a sum type by construction, with no dead fields**, obtained without anyone
writing a `DrawOp` declaration. The macro's per-argument spec is a triple of
`clone-` / `convert-` / `unconvert-` functions, so the encoding of each payload
type is declared once beside the operation.

[F3][comparison] refined: a method-dispatch seam **and** a reified,
comparable, serialisable stream are compatible, provided the recorder is
generated from the seam's declaration instead of being a parallel data type
kept in sync by hand. The macro also settles F3's open trade by construction —
each command's payload is exactly its argument list, so nothing is as wide as
the widest operation, and the set is still closed because the method set is.

`sparkles:ui` derives what it can and declares the rest by hand. `OpKind` is
computed from `DrawOp` by an eight-arm `match!`, so those two cannot disagree —
[F11][comparison] applied. The declaration that stands apart is `isCanvas`
itself, which names five methods while the interpreter calls eight kinds,
probing the other four with `__traits(compiles)` at each site: [friction
§2][friction] is exactly the drift a recorder generated from one declaration
makes impossible.

## Q5 — sub-unit placement

Coordinates are `real?` throughout, so a band along an edge is never spelled as
a compass direction ([friction §5][friction]). Continuous coordinates do not
thereby dissolve the sub-unit question — they move it onto the device, which is
[F6][comparison] in one subject. What Racket adds beyond the other
continuous-coordinate subjects is a **named snapping policy** for it:

- `set-smoothing` takes `'unsmoothed`, `'smoothed` or `'aligned`. Both
  `'unsmoothed` and `'aligned` "adjust drawing coordinates to match pixel
  boundaries" ([`dc-intf.scrbl`][dc-doc]).
- `set-alignment-scale` says _what_ grid to snap to: the default `1.0` "means
  that drawing coordinates and pen sizes are aligned to integer values", while
  "An alignment scale of `2.0` aligns drawing coordinates to half-integer
  values" — for a bitmap with a backing scale of `2.0` ([`dc-intf.scrbl`][dc-doc]).
- **A pen of width `0` means "hairline", and the device decides what that is.**
  In `dc.rkt`, a zero width becomes `1/effective-scale-x` in aligned mode and
  otherwise `(get-hairline-width effective-scale-x)`; the default backend
  returns `1/sx` (one device unit) and `post-script-dc%` overrides it to
  `(/ 1.0 (* cx 4))` — a quarter of a device unit, because PostScript's device
  unit is a point, not a pixel.

That last bullet is the survey's second independent confirmation of
[F6][comparison]'s "a named fidelity plus a queried device unit", arriving from
the opposite direction to Notcurses: the caller writes `0`, meaning _as thin as
this device can honestly draw_, and four backends answer differently — and
`get-hairline-width` is the queried unit that makes the name resolvable.
`sparkles:ui`'s `RuleEdge` names six positions where a hairline **width**
supplied by the backend would name none.

## Q7 — payload ownership

Live drawing borrows: `draw-text` takes a `string?`, `draw-bitmap` takes a
`bitmap%`, and neither is retained past the call.

Recording is where ownership is decided, and `record-dc%` decides it **per
argument, twice over**. Each recorded parameter names up to three functions —
`clone-id`, `convert-id`, `unconvert-id` — so the same argument gets a deep-copy
encoding for in-memory replay (`clone-bitmap`, `clone-pen`, `clone-color`) and a
plain-data encoding for serialisation (`convert-color` reduces a `color%` to
`(list r g b a)`; `unconvert-pen` rebuilds one through `the-pen-list`'s
interning `find-or-create-pen`). Strings become immutable on the way in.

Two consequences worth carrying. **A recorded command can outlive not just the
frame but the process** — a stronger property than any other subject offers, and
what makes a recorded drawing a golden-test _artefact_ rather than a golden-test
output. And **retention is bounded on purpose**: `set-recording-limit` plus
`continue-recording?` stop recording past an accumulated size
([`record-dc.rkt`][record-src]), where `RecordingCanvas` collects into an
unbounded GC array and `CmdBuffer` reports a `length` that nothing caps.

Racket agrees with [F8][comparison] and shows the shape of the agreement:
per-argument, and different on the two paths. `sparkles:ui` splits the same way
— `CmdBuffer.textRun` copies its bytes into a `FrameArena`, which is what makes
a `scope` source safe to draw with, while `RecordingCanvas` interns on the
collected heap so its operations outlive the call that drew them. What Racket
has and the arena path does not is a payload that survives the buffer:
[friction §7][friction] is the rule _an operation is valid while the buffer that
built it is alive and unreset_, stated on the type and therefore enforceable,
but still a borrow — which is the retain boundary `UI-O4` holds open. Racket's
`convert-`/`unconvert-` pair is what closing it looks like: a plain-data
encoding declared beside the operation, chosen per argument.

## Q8 — extent query

**Racket answers this three times, and the three answers are different things.
It is the fullest confirmation of [F7][comparison] in the survey.**

| Query                                       | Owner               | What it means                                        |
| ------------------------------------------- | ------------------- | ---------------------------------------------------- |
| `get-size`                                  | the **device**      | the destination drawing area — F7's surface question |
| `get-ink-extent`                            | the **recording**   | the bounding box of what was actually drawn          |
| `pict-width`/`-height`/`-ascent`/`-descent` | the **scene value** | the declared layout box, computed at construction    |

`get-size` is the uncontroversial one: the docs enumerate it per backend (window
client size, selected bitmap size — "or 0 if no bitmap is selected" — or the
page drawing area), and `post-script-dc%` computes it from paper size minus
margins over the configured scale ([`post-script-dc.rkt`][ps-src]).

`get-ink-extent` is the second question, answered separately. `record-dc%`
takes a `record-ink?` initialisation argument; when true it allocates a Cairo _recording surface_ and
returns the extent from `cairo_recording_surface_ink_extents`. The docs draw a
distinction that a scan over operation rects cannot make:

> Bounding drawing "ink" takes into account the visible effect of drawing with
> different pen widths and the shape of drawn text, as opposed to just
> collecting path coordinates and nominal text extents.
>
> — [`record-dc-class.scrbl`][record-doc]

It is **opt-in**, precisely because it costs a surface; without it the method
raises rather than guessing. Note also why a recorder needs a live Cairo
context even when it never paints: "We need a cairo context and surface to
measure text, at least" ([`record-dc.rkt`][record-src]) — Q1's dissent charging
rent on Q8's answer.

On the pict side there are again two: the declared box (`width`/`height`) and
the `panbox`, the "panorama box, computed on demand" by `panorama-box!` — a
memoised recursive union over `children` that is **larger** than the declared
box whenever a child draws outside its bounds. `convert-bounds-padding`
defaults to `'(3 3 3 3)` "to accommodate a small amount of drawing outside the
pict's bounding box" when converting to PNG or PDF ([`pict.scrbl`][pict-doc]).

So **"extent" is three questions, not one** — the surface extent (who
allocates), the layout extent (who arranges) and the ink extent (who crops).
Racket ships all three, with the expensive one behind a flag, and it sits on
the maintained-at-construction side of [F7][comparison]'s axis for the layout
one: a pict's box is a field, fixed when the pict is built, and even the
panorama box is memoised rather than re-walked. `sparkles:ui` answers none of
the three from the seam. `CmdBuffer` reports an operation count and a run's cell
extent; nothing on it, the display list or the arena reports the extent of a
built stream, so a caller that needs painted bounds folds `op.rect` itself
([friction §8][friction]) — the derived-by-scan side of the same axis, and a
scan that reads a `TextRun`'s declared cell advance rather than its ink.

## Strengths

- **One declaration, contract-checked, no probing.** `dc<%>` is a value; a
  backend author reads one file, and a violation is a contract error at the
  boundary.
- **Degradation lives in the framework, once**, driven by private per-device
  predicates (`can-mask-bitmap?`, `get-hairline-width`, `dc-adjust-smoothing`,
  `collapse-bitmap-b&w?`) rather than in each caller.
- **The recorder is generated from the seam**, so the reified command stream
  cannot drift from the method set, and it serialises.
- **Hairline as a device-supplied width** (pen width `0`) instead of an
  enumerated position.
- **Command/query partition is mechanised** by `check-page-active`'s explicit
  fifteen-method list.
- **`pict` proves an image algebra needs no device for composition** — only for
  its text leaves — with extent as an ordinary immutable field.

## Weaknesses

- **Measurement on the device forces a global sizing parameter.** `dc-for-text-size`
  is process state; getting it wrong is silent and unrecoverable, because pict
  extents are frozen at construction.
- **The metric-universe assumption is stated but unenforced.** `get-font-metrics-key`
  proves PostScript and SVG measure differently from bitmaps; nothing checks
  that the sizing DC and the target DC share a key.
- **Capability is private.** An application cannot ask whether alpha will
  survive; it can only read that PostScript rounds it to 0 or 1.
- **Silent no-ops for a mis-sequenced `bitmap-dc%`.** "the method call is
  ignored" is the least debuggable degrade in the survey.
- **72 members is a high floor** for a new backend, even with `dc-mixin` doing
  most of the work.
- **Out-of-band appearance makes replay expensive**: fourteen state settings
  saved and restored around every recorded drawing.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                                   | Trade-off                                                                         |
| --------------------------------------------------- | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `get-text-extent` on `dc<%>`                        | the device is the only thing that truly knows its shaping and metrics       | needs a DC to measure at all; forces `pict`'s global `dc-for-text-size` parameter |
| One total 72-member interface, no capability query  | callers write one code path; the contract is a single readable value        | totality is a fiction, upheld by no-ops, rounding and documented lossiness        |
| Capability predicates on a **private** backend seam | framework degrades once, consistently                                       | applications cannot negotiate or refuse a degrade                                 |
| Appearance as device state, not per-command fields  | commands stay minimal; matches the PostScript model                         | replay must save/restore fourteen settings; no per-op semantic role survives      |
| Pen width `0` = device-defined hairline             | each device names its own thinnest honest stroke                            | a caller cannot ask how thin that is before drawing                               |
| Extent stored in the pict at construction           | composition is pure arithmetic over `w h a d`; arbitrary layout computation | a wrong sizing DC bakes a wrong layout permanently; declared box ≠ ink box        |
| Recorder generated by macro over the method set     | reified stream cannot drift; serialisable and replayable                    | recording is a mixin over a live backend, so it still needs a Cairo context       |
| Ink extent behind `record-ink?`                     | costs a recording surface, so opt in                                        | absent by default; the method raises rather than approximating                    |

## Bearing on the proposal

1. **Q1 stays decided, but for a sharper reason.** Racket is the one surveyed
   subject that puts measurement on the painter, and it pays with a global
   parameter, a wasted surface, and an unchecked correspondence between sizing
   device and target device. That does not falsify [F1][comparison] — it is the
   priced dissent inside it. `Size measure(const(char)[])` on `isCanvas` is the
   same placement; [friction §1][friction] is the bill in our units, and Racket
   is the bill in the other currency.
2. **Steal `get-font-metrics-key` outright.** A small integer identifying a
   metric universe, `0` meaning "not cacheable", lets a toolkit cache measured
   text across backends **and** detect the case where a layout was measured
   against the wrong one. Whatever font abstraction replaces `measure` on
   `isCanvas` should carry one. Nothing else in the survey has this.
3. **Generate the recorder from the seam declaration.** [Friction §2][friction]
   is the gap between the five methods `isCanvas` checks and the eight kinds the
   interpreter calls. `DrawOp.kind` is the cheap half of the answer: an
   eight-arm `match!` rather than a stored tag, so no walker can read a kind the
   payload contradicts, which is [F11][comparison] in miniature.
   `record-dc-mixin` shows how far the same move goes: derive the conforming
   backend, the op encoding and the method set from one declaration and none of
   the three can disagree. It also settles [F3][comparison]'s live trade for
   free — a tag that is the operation's own name, carrying only its live
   arguments, with no operation as wide as the widest.
4. **Replace `RuleEdge` with a backend-supplied hairline width, not more
   enumerators.** Racket's pen-width-`0` convention plus `get-hairline-width`
   (`1/sx` on screen, `1/(4·sx)` for PostScript) is [F6][comparison]'s "a named
   fidelity plus a queried device unit" in its simplest possible form. The
   caller names the fidelity; the device answers with the unit. That is the
   pattern [friction §5][friction] needs whether or not we adopt continuous
   coordinates.
5. **Partition the seam into commands and queries, mechanically.**
   `check-page-active`'s explicit fifteen-method list is what
   [friction §2][friction] wants: the drawing subset named in one place rather
   than inferred. Ours would additionally make clear which members a
   `RecordingCanvas` must record and which it must answer.
6. **Confirms [F7][comparison] in full, and names the owner of each third.**
   Racket ships **surface** extent (`get-size`), **ink** extent
   (`get-ink-extent`, opt-in), and **layout** extent (the pict fields) — and
   `pict` cannot function without the third. Take the same split: the _surface_
   extent belongs to the surface; the _ink_ extent is a legitimate scene query
   worth paying for only when asked; the _layout_ extent belongs to the layout
   pass, which is where [friction §8][friction]'s offscreen consumer should get
   it. `skia-canvas-render.d` folds `op.rect` across the stream, which reaches
   for the third answer through the second's door and gets a cell advance
   instead of an ink box.
7. **Bound the recorder.** `CmdBuffer` reports its operation count and nothing
   acts on it. `set-recording-limit` costs almost nothing and turns an unbounded
   `DrawOp[]` into a degradation with a stated ceiling — which is also what
   keeps [F12][comparison]'s parity oracle affordable to keep inspecting.
8. **Do not adopt out-of-band appearance.** [Friction §6][friction] calls
   storing a resolved appearance beside a semantic `Slot` a hedge, and
   [F9][comparison] counts seven encodings that cost less. Racket is the
   cheapest of them and shows its full bill — fourteen state settings saved and
   restored around every replay, and no semantic role surviving into the stream
   at all, which is fatal for the HTML interpreter that re-resolves class names
   from the role. For a seam whose whole justification is a comparable op
   stream, per-op payload is the right side of this trade even though it is the
   more expensive one per command. The saving to chase is the one the seam
   taken here — store what a primitive paints from and derive `Visual` at the
   asking — not the transposition.

## Sources

- [`dc-intf.rkt`][dc-intf-src] — the `dc<%>` declaration: 72 contracted members, `#:public` defaults on `start-alpha`/`end-alpha`.
- [`dc.rkt`][dc-src] — `dc-backend<%>`, the private capability seam, and `dc-mixin`, the shared degrading implementation.
- [`record-dc.rkt`][record-src] — `define/record`, the dual closure+datum encoding, `set-recording-limit`, `get-ink-extent`.
- [`post-script-dc.rkt`][ps-src], [`svg-dc.rkt`][svg-src] — per-device `get-font-metrics-key`, `can-mask-bitmap?`, `get-hairline-width`, `get-size`.
- [`page-dc.rkt`][page-src] — `doc+page-check-mixin` and the fifteen-method `check-page-active` list.
- [`dc-intf.scrbl`][dc-doc], [`bitmap-dc-class.scrbl`][bitmap-dc-doc], [`record-dc-class.scrbl`][record-doc], [`post-script-dc-class.scrbl`][ps-doc], [`svg-dc-class.scrbl`][svg-doc], [`guide.scrbl`][guide], [`blurbs.rkt`][blurbs] — the documented capability differences and the `PrintNote` lifecycle rule.
- [`pict.rkt`][pict-src] — the pict struct, `dc-for-text-size`, `text`, the append/superimpose factories, `panorama-box!`.
- [`pict.scrbl`][pict-doc] — the bounding-box model, `dc-for-text-size`, `convert-bounds-padding`, the combinator reference.
- [`printer-dc-class.scrbl`][printer-doc] — `printer-dc%`, a `dc<%>` implementation that lives in another package.

Revisions pinned with `gh api repos/<owner>/<repo>/commits/master --jq .sha` and
every path verified by fetching it at that SHA from `raw.githubusercontent.com`.

<!-- References -->

[rev-draw]: https://github.com/racket/draw/tree/c2f36f533ea6ee3f6400bf352d3d511dbf659916
[rev-pict]: https://github.com/racket/pict/tree/f96ef6a7c26dbe38c1c8c958a9fd7e25bd521fbc
[license]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/LICENSE
[dc-intf-src]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-lib/racket/draw/private/dc-intf.rkt
[dc-src]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-lib/racket/draw/private/dc.rkt
[record-src]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-lib/racket/draw/private/record-dc.rkt
[ps-src]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-lib/racket/draw/private/post-script-dc.rkt
[svg-src]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-lib/racket/draw/private/svg-dc.rkt
[page-src]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-lib/racket/draw/private/page-dc.rkt
[dc-doc]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-doc/scribblings/draw/dc-intf.scrbl
[bitmap-dc-doc]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-doc/scribblings/draw/bitmap-dc-class.scrbl
[record-doc]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-doc/scribblings/draw/record-dc-class.scrbl
[ps-doc]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-doc/scribblings/draw/post-script-dc-class.scrbl
[svg-doc]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-doc/scribblings/draw/svg-dc-class.scrbl
[guide]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-doc/scribblings/draw/guide.scrbl
[blurbs]: https://github.com/racket/draw/blob/c2f36f533ea6ee3f6400bf352d3d511dbf659916/draw-doc/scribblings/draw/blurbs.rkt
[pict-src]: https://github.com/racket/pict/blob/f96ef6a7c26dbe38c1c8c958a9fd7e25bd521fbc/pict-lib/pict/private/pict.rkt
[pict-doc]: https://github.com/racket/pict/blob/f96ef6a7c26dbe38c1c8c958a9fd7e25bd521fbc/pict-doc/pict/scribblings/pict.scrbl
[printer-doc]: https://github.com/racket/gui/blob/f534929f1f77e7b491d1ef1d74a372241d2a7c61/gui-doc/scribblings/gui/printer-dc-class.scrbl
[comparison]: ./comparison.md
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
