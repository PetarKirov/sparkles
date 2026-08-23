# Notty — the scene is an algebra, and the backend is twelve closures

**Category:** image algebra (cell), with stated laws. **Last reviewed:** August 23, 2026.
Pinned at [`e035d069`][rev].

Notty is the only subject in this survey whose seam is defined by **laws written
down in the interface file**. Its `image` is an immutable value with two
associative composition operators and an identity; its backend is a single
record of twelve output closures. Where [egui](./egui.md) reifies a command
stream and [Slint](./slint.md) dispatches through a trait, Notty reifies the
_scene_ — and derives a command stream from it, per row, per viewport, at render
time, then throws it away.

| Field            | Value                                                                      |
| ---------------- | -------------------------------------------------------------------------- |
| Language         | OCaml                                                                      |
| License          | ISC ([`notty.opam`][opam])                                                 |
| Repository       | [`pqwy/notty`][repo]                                                       |
| Documentation    | the interface file itself, [`src/notty.mli`][mli] (odoc)                   |
| Category         | image algebra (cell), with stated laws                                     |
| Pinned revision  | `e035d069370da436f1fc53525c1e16bff3ed687e`                                 |
| Latest release   | `v0.2.3`, 2022-09-02 ([`CHANGES.md`][changes])                             |
| Target range     | character cells only — no sub-cell, no pixels, no GPU                      |
| Backends shipped | `Cap.ansi` and `Cap.dumb` ([`notty.ml:540`][cap-ansi], [`:555`][cap-dumb]) |
| IO modules       | `Notty_unix`, `Notty_lwt` — separate packages; the core does no I/O        |
| Unicode data     | vendored Unicode 13 subset of `Uucp`/`Uuseg` ([`src/no-uucp/`][nouucp])    |

Cross-reference: [`tui-libraries/nottui.md`](../tui-libraries/nottui.md) treats
Notty as Nottui's rendering dependency. This page treats it as the subject.

## Overview

### What it solves

Notty removes the terminal's programming model from the application. There is no
cursor to move, no screen to clear, no ordering constraint between drawing
operations. An application builds one `image` value and hands it over; the
library decides what bytes that means.

> - Why make yet another terminal output library?
>
>   Because:
>   - It allows one to _describe_ what should be seen, as opposed to _commanding_
>     a terminal.

— [`README.md`][readme-what]

### Design philosophy

The core module is explicitly platform-free:

> This module provides the core `image` abstraction, standalone rendering, and
> escape sequence parsing. It does not depend on any platform code, and does not
> interact with the environment. Input and output are provided by `Notty_unix`
> and `Notty_lwt`.

— [`src/notty.mli:9`][mli-intro]

The consequence for this survey is that the seam is not a drawing interface at
all. Nothing a backend can be handed is a "draw call": the backend is handed a
finished value plus a viewport, and asked for bytes.

Notty credits [Vty][vty] as its ancestor ("Notty's core API was heavily
influenced by Haskell's Vty", [`README.md`][readme-vty]), which is why it is on
this list: it is the deliberate, law-stated version of an idea Vty arrived at
first.

## How it works

### The image is a sum type with cached dimensions

```ocaml
type dim = int * int

type t =
  | Empty
  | Segment  of A.t * Text.t
  | Hcompose of (t * t) * dim
  | Vcompose of (t * t) * dim
  | Zcompose of (t * t) * dim
  | Hcrop    of (t * int * int) * dim
  | Vcrop    of (t * int * int) * dim
  | Void     of dim
```

— [`src/notty.ml:232`][img-type]

Eight constructors, each carrying exactly the payload its case needs. Every
composite caches its own `dim`, computed by the smart constructor at build time,
so [`I.width`][img-width] and [`I.height`][img-height] are a single pattern match
— they are marked `[@@inline]`.

### The laws, stated in the interface

The two axes of composition are documented as a monoid:

> Three basic composition modes allow construction of more complex images from
> simpler ones.
>
> Composition operators are left-associative and form a monoid with `void`.

— [`src/notty.mli:229`][mli-comp]

with per-operator dimension laws given individually — `width (i1 <|> i2) = width i1 + width i2`
and `height (i1 <|> i2) = max (height i1) (height i2)` for beside, the transpose
for above, `max` on both axes for over ([`src/notty.mli:237`][mli-beside],
[`:253`][mli-above], [`:268`][mli-over]).

The identity is `Empty`, reached from the documented `void` by the collapse rule
`void 0 0 = empty` ([`src/notty.mli:225`][mli-void]); `void w h` returns `Empty`
when both dimensions are below 1 ([`notty.ml:305`][img-void]). Each operator
pattern-matches `Empty` on either side and returns the other operand unchanged,
so the identity is realised in the term, not merely respected in the semantics:

```ocaml
let (<|>) t1 t2 = match (t1, t2) with
  | (_, Empty) -> t1
  | (Empty, _) -> t2
  | _          ->
      let w = width t1 + width t2
      and h = max (height t1) (height t2) in
      Hcompose ((t1, t2), (w, h))
```

— [`src/notty.ml:281`][img-hcat-op]

> [!NOTE]
> The stated law names `void` as the unit where the implementation's unit is
> `Empty`. The two are reconciled by the documented `void 0 0 = empty`, but the
> interface says `void` — a family of values — rather than that equation. The
> laws are also **not machine-checked**: at this revision the tree carries
> `examples/` and `benchmarks/` and no test directory; the `README` says the
> example programs "also double as tests" ([`README.md`][readme-tests]).

### The laws are load-bearing, not decorative

Two core combinators depend on associativity to rebalance the term. `hcat`/`vcat`
fold through `concatm`, which repeatedly pairs _adjacent_ elements rather than
folding down a left spine:

```ocaml
let rec concatm z (@) xs =
  let rec accum (@) = function
    | []|[_] as xs -> xs
    | a::b::xs -> (a @ b) :: accum (@) xs in
  match xs with [] -> z | [x] -> x | xs -> concatm z (@) (accum (@) xs)
```

— [`src/notty.ml:19`][concatm], used as `let hcat = concatm empty (<|>)`
([`:338`][hcat]); `I.tabulate` bisects the same way through `linspcm`
([`:25`][linspcm], [`:351`][tabulate]). Both build a tree of depth `log n`
instead of a spine of depth `n`, and both are correct only because the operator
is associative with `empty` as unit. That is why a seam benefits from stated
laws: they buy the implementation freedom to re-associate.

### Rendering: image + viewport + `Cap` → bytes

The entire render seam is one function:

```ocaml
val to_buffer : Buffer.t -> Cap.t -> int * int -> int * int -> image -> unit
(** [to_buffer buf cap (x, y) (w, h) i] … renders the [w * h] rectangle of [i],
    offset by [(x, y)] from the top left. *)
```

— [`src/notty.mli:425`][mli-render]

Two stages. `Operation.of_image` traverses the image once per output row,
producing a per-row list in a three-constructor language:

```ocaml
type t =
  End
| Skip of int * t
| Text of A.t * Text.t * t
```

— [`src/notty.ml:428`][op-type]

`Render.lines` then walks those rows against a `Cap.t`
([`src/notty.ml:586`][render-line]). The op language is marked private in the
interface — "These are private interfaces, prone to breakage. Don't use them."
([`src/notty.mli:609`][mli-private]) — which is the point: the durable value is
the image, not the op stream.

The third argument, `Cap.t`, is the backend — a record of twelve mandatory
closures of type `Buffer.t -> unit`, covered under Q2.

## Q1 — measurement unit, and who answers

**Nobody asks, because the answer is an invariant of the value.** A `Segment`'s
width is fixed when the segment is _constructed_, before any `Cap` exists:
`I.string` calls `Text.of_string`, which for non-ASCII input runs the vendored
grapheme segmenter and sums `Notty_uucp.tty_width_hint` per cluster
([`src/notty.ml:92`][graphemes], [`notty_uucp.mli`][uucp-mli]). `I.width` then
reads a cached integer.

This is a fifth route past the four [`comparison.md`](./comparison.md)'s F1
enumerates, and the most extreme: measurement is not a painter service, a
parallel metrics class, or a pre-resolution pass — it is a **constructor
postcondition**. An image whose width you cannot compute cannot be built.

The honesty is in the naming: `tty_width_hint`. The failure modes are stated
plainly rather than papered over:

> Geometry in general works for alphabets and east Asian scripts, mostly works
> for abjad scripts, and is a matter of luck for abugidas.
>
> For proper emoji display, `Uucp` and the terminal have to agree on the Unicode
> version.

— [`src/notty.mli:700`][mli-cwidth]

The pinned data is Unicode 13 ([`CHANGES.md`][changes]), so that agreement is a
build-time constant the terminal may not share. The only sub-cell fact in the
library falls out of the same place — a crop that splits a double-width cluster
substitutes a space:

> When a crop splits a wide character in two, the remaining half is replaced by
> `U+0020` (SPACE). Hence, character-cell-accurate cropping is possible even in
> the presence of characters that horizontally occupy more than one cell.

— [`src/notty.mli:724`][mli-cwidth]; implemented via the `-1` index sentinel and
`Text.dead = ' '` in [`Text.to_buffer`][text-tobuffer].

**Bearing on friction §1:** Notty cannot be copied wholesale — one target, a
monospace axiom, so it never faces `SkiaCanvas.measure` having to lie. But it
removes an assumption `isCanvas` makes: that measurement is a _query_ at all. If
a run's advance is computed once, where the run enters the display list, no
backend is ever asked and none can disagree.

## Q2 — is the contract stated in one place?

**Yes, exhaustively, as a record of closures — and there is no optionality.**

```ocaml
type op = Buffer.t -> unit

type t = {
  skip    : int -> op ; sgr     : A.t -> op ; newline : op ; clreol : op
; cursvis : bool -> op ; cursat  : int -> int -> op ; cubcuf : int -> op
; cuucud  : int -> op ; cr : op ; altscr : bool -> op
; mouse   : bool -> op ; bpaste : bool -> op }
```

— [`src/notty.ml:490`][cap-type]; the interface calls it "A set of capabilities
that distinguish terminals from one another. A bundle of magic strings, really."
([`src/notty.mli:408`][mli-cap]).

Twelve fields, all mandatory. A new backend is a value of that type; the type
checker enumerates the obligations; nothing is discovered by probing. The
degradation mechanism is the interesting half — `Cap.dumb` does not omit
capabilities, it supplies no-ops:

```ocaml
let no0 _ = () and no1 _ _ = () and no2 _ _ _ = ()

let dumb = {
    skip    = (fun n b -> Buffer.add_chars b ' ' n)
  ; newline = (fun b -> b <| "\n")
  ; altscr  = no1 ; cursat = no2 ; sgr = no1 (* … *) }
```

— [`src/notty.ml:555`][cap-dumb]

Every field is total; "unsupported" is spelled as a function that writes nothing.
The caller — `Render.line` — never branches on what the backend can do. Contrast
`isCanvas`, where `rule`, `scrollbar` and the clip pair are rediscovered by
`__traits(compiles)` at each interpreter call site.

Backend selection is a two-line environment decision made once, in the IO layer,
not in the core:

```ocaml
let cap_for_fd =
  match Sys.getenv "TERM" with
  | exception Not_found -> fun _ -> dumb
  | (""|"dumb")         -> fun _ -> dumb
  | _                   -> fun fd -> if Unix.isatty fd then ansi else dumb
```

— [`src-unix/notty_unix.ml:20`][capforfd]

**Bearing on friction §2 and F5:** this is a third model beside Qt's declared
feature set and our probing — a **total contract with null implementations**. It
is strictly cheaper than either, and it is affordable exactly because every
primitive in the seam degrades to nothing without breaking the frame. It does not
generalise to a seam containing `scrollbar`, because dropping a scrollbar is not
a survivable no-op. That is a useful inversion: how narrow a seam has to be
before "just supply a no-op" is a valid capability story.

## Q3 — semantic operations or primitives?

**The most primitive seam in the survey — three op constructors, and no geometry
at all.** After `Operation.of_image`, a row is a sequence of "skip `n` columns"
and "emit this styled text". There is no rectangle, no line, no border, no
shadow, no scrollbar. Even the fill primitives are text: `I.char`/`I.uchar`
build a `w * h` block by tabulating a replicated `Text` segment
([`src/notty.ml:355`][chars]).

Notty is therefore further from [Slint](./slint.md)'s eight semantic operations
than [egui](./egui.md) is — egui's `Shape` still names circles, paths and meshes.
It can afford that because the _composition layer above_ the seam is the widget
vocabulary: `<|>`, `<->`, `</>`, crop, pad, snap and `tabulate` are what
[Nottui](../tui-libraries/nottui.md) builds boxes and tables from, and none of it
reaches the backend.

**Bearing on F4:** F4 recasts the question as _where the lowering lives_, and
enumerates "nobody" as one of the six answers. Notty is that answer's clearest
witness: nothing is lowered because nothing above a styled cell run is ever
named, so the seam sits below the level at which fidelity is a question. It is a
genuine option, bought by having exactly one class of target; `sparkles:ui`
cannot buy it while a cell grid and Skia share a seam, which sharpens the
umbrella's open question rather than answering it.

## Q4 — command shape

**Two sum types, at two levels, and only one of them is durable.** `I.t` is an
8-constructor variant; `Operation.t` is a 3-constructor variant. Neither is a tag
plus fields that are dead for most tags, which is the same encoding decision
`sparkles.input.events` and `DrawOp` both make — a closed sum over per-kind
payloads, with each arm carrying only what its own case needs.

That makes Notty a second witness for the side of F3's live trade `sparkles:ui`
sits on: a closed sum eliminates the illegal combinations and keeps the values
comparable. What Notty does not pay is the cost
[friction §4](../../specs/ui-skia/canvas-seam-friction.md) records against a sum
held **by value**. OCaml's constructors are boxed blocks sized per arm, so
`Skip` is a two-field block and `Text` a three-field one; a `SumType` stored
inline in a flat `DrawOp[]` is as wide as its widest arm, so a `PopClip` that
carries nothing costs what a text run costs. Variable stride is free to a
language that already indirects every arm, and is the whole trade for one that
does not.

Notty also **complicates F3's framing**. F3 holds that reifying the command
stream is what buys recording, replay, culling and comparison. Notty reifies
_above_ it: the image is what is retained, compared, cached and passed between
layers, while the flat op stream is derived per row, per viewport, and discarded.
The recordable, comparable artefact — `RecordingCanvas`'s whole purpose — is
available on the _scene_:

> `equal t1 t2` is `true` iff `t1` and `t2` are constructed by the same term.
>
> **Note** This is a weak form of equality. Images that are not `equal` could
> still render the same.

— [`src/notty.mli:186`][mli-equal]

Intensional equality, deliberately, and cheap: [`I.equal`][img-equal]
short-circuits on cached dimensions before recursing. A golden test comparing op
streams compares the _lowered_ form; Notty shows the source form is both
comparable and cheaper.

The cost of the value-algebra is documented with equal candour:

> **TL;DR** Shared sub-expressions do not share work, so operators stick with
> you.

— [`src/notty.mli:876`][mli-perf]

Complexity counts operators in the fully expanded term, **ignoring all sharing** —
`let x = i <|> i in x <-> x` costs the same as writing `i` four times
([`src/notty.mli:897`][mli-perf]). The tree is a tree, not a DAG; the interface
teaches an O(n) line-wrap idiom because the naive O(n²) one is a real hazard
([`:935`][mli-perf]).

## Q5 — sub-unit placement

**Does not arise, and the absence is informative.** No unit below a cell and no
ambition to acquire one: no rules, no hairlines, no lines, no box-drawing helper.
A border is whatever `U+2500`-family characters the application composes with
`<|>` and `<->`. Where [Notcurses](./notcurses.md) answers our constraint by
naming a _fidelity_, Notty declines the question. The single concession is repair,
not placement: the space substituted for the severed half of a wide cluster (Q1).

**Bearing on friction §5:** this is the null hypothesis `RuleEdge` should be
measured against. A cell toolkit that refuses sub-cell expression has no
enumerator to grow — and the reason `sparkles:ui` cannot take that option is
Skia, not the terminal. That locates §5's cost precisely: it is the price of one
seam spanning both targets, not a defect of cell geometry.

## Q6 — resolved appearance, semantic role, or both?

**Resolved only — and resolution is itself an algebra.** `A.t` is a separate,
composable type carried on the `Segment` constructor, never on the composition
nodes. It is three machine words:

```ocaml
type color = int
type style = int
type t = { fg : color; bg : color; st : style }
```

— [`src/notty.ml:164`][attr-type]. Colors are tagged integers (`0` = unset, tag `1` = palette index, tag `2` = 24-bit
RGB, [`notty.ml:189`][attr-tag]); styles are a bitmask. The combining operator is
its own documented monoid:

> `a1 ++ a2` is the concatenation of `a1` and `a2`, the attribute that has `a2`'s
> foreground (resp. background), unless _unset_, in which case it is `a1`'s, and
> the union of both style sets.
>
> `++` is left-associative, and forms a monoid with `empty`.

— [`src/notty.mli:156`][mli-attr-cat]; implemented at
[`src/notty.ml:219`][attr-cat], with `empty` short-circuited by physical
equality.

For [friction §6](../../specs/ui-skia/canvas-seam-friction.md): where Notty
puts one value on the constructor, `sparkles:ui` writes two into most of its
arms — the resolved fields a primitive paints from, and, on six of the eight
payloads, the `Slot` those fields were resolved out of — because one interpreter
re-resolves the role into class names while the pixel backends read the resolved
half. Notty carries the resolved half alone and gets _cascading_ anyway,
because "unset falls through to the outer attribute" is a law on the value type
rather than a lookup at paint time — a seventh cheap encoding beside the ones F9
enumerates, and the only one that buys inheritance without a role. The one
place a role could still be reinterpreted is `Cap.sgr`, the single function
turning an attribute into bytes — `dumb` sets it to `no1` and every colour
evaporates ([`notty.ml:569`][cap-dumb]).

The honest limit is the direction F9 names: Notty's attributes are fully
resolved colours, so an HTML backend could not recover a class name from one.
Like Slint, it has no re-resolving consumer and pays for one representation, not
two. What it shows is that a _composable_ resolved type absorbs some of the work
a semantic slot carries — not all of it, and not the part `sparkles:ui` keeps
`Slot` for.

## Q7 — payload ownership

**Shared, immutable, garbage-collected — a payload outliving its frame is the
normal case, not a hazard.** `Text.t` wraps an OCaml `string` (immutable) plus a
grapheme index array; `Text.sub` is O(1) and shares both, adjusting an offset and
a width ([`src/notty.ml:121`][text-sub]). An image can be built once, stored, and
rendered into any number of frames at any number of viewports; Nottui's whole
incremental model depends on that.

Two mechanisms are directly transferable:

1. **A library-owned memo for expensive construction.** Unicode segmentation is
   run behind a weak-keyed cache: `let of_unicode = memo ~eq:String.equal ~size:128 of_unicode`
   ([`src/notty.ml:143`][of-unicode]), where `memo` is an `Ephemeron.K1.Make`
   table ([`:30`][memo]). The `CHANGES` entry for `v0.2.1` is "Cache the internal
   representation of Unicode strings" ([`CHANGES.md`][changes]). This is
   [Slint](./slint.md)'s `draw_cached_pixmap` idea applied to text measurement,
   keyed by content instead of by item.
2. **Cropping as a value, not a painter mode.** `Hcrop`/`Vcrop` are image
   constructors; the render traversal pushes the offset down rather than
   materialising anything ([`src/notty.ml:478`][scan-crop]). Clipping is
   therefore total, always available, and composes — the opposite of an optional
   `pushClip`/`popClip` pair discovered by introspection.

**Bearing on friction §7 and F8:** F8 finds that every one of thirty-eight
subjects copies, refcounts or arena-allocates a payload rather than borrowing it
across a frame. `sparkles:ui` is on that list by the third mechanism —
`CmdBuffer.textRun` copies the run into a frame arena, which is what makes a
`scope` source safe to draw from — and Notty is the survey's purest case of the
second. What Notty adds is _where the remaining cost sits_. `DrawOp.text` is a
slice of arena bytes, valid while the buffer that built it is alive and unreset,
so the rule is stated on the type and the buffer is move-only to keep it true.
Where the scene is the durable value, the payload's lifetime is the scene's, and
the retain-and-transfer question `UI-O4` holds open — recording on one thread and
submitting on another — does not arise to be answered.

## Q8 — can a backend ask the scene its extent?

**Yes — in O(1), always, and the layout combinators depend on it.** Every
composite caches `dim` at construction, so `I.width`/`I.height` are a pattern
match ([`src/notty.ml:244`][img-width]).

This is not a convenience. `I.hsnap` and `I.vsnap` — the align-to-width and
align-to-height combinators — are implemented as a crop whose offsets are
computed _from the image's own extent_:

```ocaml
let hsnap ?(align=`Middle) w img =
  let off = width img - w in match align with
    | `Left   -> hcrop 0 off img
    | `Right  -> hcrop off 0 img
    | `Middle -> let w1 = off / 2 in hcrop w1 (off - w1) img
```

— [`src/notty.ml:362`][hsnap]. The interface's own worked example does the same
at application level: a line that stretches end-to-end is
`I.(i1 <|> void (w - width i1 - width i2) 1 <|> i2)`
([`src/notty.mli:833`][mli-stretch]).

**This is F7's three questions, answered separately in one library.** Surface
extent comes from outside: `to_buffer` takes the viewport `(w, h)`, and
`Notty_unix.output_image_size` hands the application the terminal size so it can
build an image to fit ([`notty_unix.mli:160`][mli-unix-size]). Layout and ink
extent coincide in a cell algebra with no overhang, and the scene answers them
itself, in constant time, because each smart constructor maintains `dim`
incrementally. Notty is therefore the survey's sharpest case for F7's axis —
**maintained-at-construction versus derived-by-scan** — and it lands on the
maintained side without giving the surface up.

`sparkles:ui` sits on the other side of that axis. `skia-canvas-render.d` folds
every operation's rect because nothing on `CmdBuffer`, the display list or the
arena reports the extent of a built stream, and the scan is fragile precisely
because `DrawOp[]` is a flat array whose builder never computed a bound. A
builder that accumulated a bounding rect as it appended would answer in O(1),
with no new backend query at all.

## Strengths

- **Laws in the interface, and the implementation cashes them** — `concatm` and
  `linspcm` rebalance the term because associativity says they may.
- **The identity is realised in the term**: `Empty` operands are eliminated by the
  smart constructors, so a neutral element costs nothing at render time.
- **The contract is a record type** — twelve mandatory fields, checked by the
  compiler. No probing, and no gap between what the concept says and what the
  renderer calls.
- **Extent is free**: O(1) `width`/`height` makes alignment, distribution and
  stretching expressible inside the algebra.
- **Intensional `equal` on the scene** gives the golden-test property without a
  recorded command stream.
- **Candid about its own limits** — `tty_width_hint`'s failure modes, the
  sharing-blind complexity model, the O(n²) wrap trap — in the same file as the API.

## Weaknesses

- **The tree is a tree.** Sharing a sub-image does not share render work; the
  interface tells you to design around it rather than fixing it.
- **No frame diffing.** `Tmachine.refresh` re-renders the whole image and emits
  the whole viewport every time ([`src/notty.ml:886`][refresh]), where
  `sparkles:tui`'s `Screen` cell-diffs. `v0.2.0`'s "Draw over lines cell-by-cell
  instead of using erase-and-skip. Slower, but flicker-free"
  ([`CHANGES.md`][changes]) shows the budget going to correctness, not minimality.
- **Width is a build-time constant** — Unicode 13 baked in; a terminal on another
  version disagrees and nothing in the design can detect it.
- **No capability negotiation.** `Cap.dumb` is the entire fallback ladder; there
  is no way to ask for something and be told no (F5's refusable degrade).
- **The laws are unverified** — no property tests at this revision; the monoid is
  an assertion in a comment.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                      | Trade-off                                                                         |
| --------------------------------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| Scene is an immutable value algebra, not a command stream | Composable, retainable, comparable; laws license re-association                | Sharing does not reduce work; complexity counts the expanded term                 |
| Width computed at primitive construction                  | Extent is an invariant; no backend can disagree, no query exists to get wrong  | Monospace axiom is unremovable; Unicode version frozen at build time              |
| `dim` cached on every composite                           | O(1) `width`/`height` makes `hsnap`/`vsnap` and stretch idioms expressible     | Two ints per node; every smart constructor must maintain it                       |
| Backend is a total record of 12 closures                  | Contract is the type; no probing; `dumb` degrades by writing nothing           | Only viable because each primitive is a survivable no-op; no negotiation possible |
| Op language private and derived per row                   | Frees the lowering to change; keeps the durable artefact at the algebra level  | No public recordable stream; consumers compare images instead                     |
| `attr` separate and monoidal, resolved                    | Attribute cascading is a value-level law, not a paint-time lookup              | Fully resolved colours; a re-resolving backend cannot recover a role              |
| Crop/pad are image constructors                           | Clipping is total, composable and free; render pushes offsets down             | Repeated cropping inflates term complexity (the O(n²) wrap hazard)                |
| Text memoized in a weak table                             | Segmentation is the expensive step; content-keyed cache pays for repeated runs | Cache is global and fixed at 128 buckets; not tunable per application             |

## Bearing on the proposal

1. **Extent should be maintained, not queried or scanned.** Notty answers Q8 in
   O(1) because every composite caches its dimensions at construction, which puts
   it on the maintained side of F7's axis while the surface still supplies the
   viewport. `buildDisplayList` can accumulate a bounding `Rect` as it appends and
   expose it on the display list, closing
   [friction §8](../../specs/ui-skia/canvas-seam-friction.md) with no new backend
   method and no scan — and the display list's own layout extent is exactly the
   question a backend allocating an offscreen surface is asking.
2. **State laws for the op stream.** The transferable part is not OCaml
   variants — `DrawOp` is already the closed sum F3 weighs — but that a documented
   identity and associativity let the _builder_ re-associate, batch and elide
   neutral elements without asking anyone. `sparkles:ui` has an op-stream parity
   harness and no stated algebra for the stream it compares, which is the gap F11
   names: the contract is stated in one place or the artifacts disagree.
3. **Compute a run's advance once, at display-list construction.** Q1 generalises
   past F1 and settles one of F2's six decisions: moving `measure` off the canvas
   is necessary, but the stronger move is making measurement a constructor
   postcondition rather than a query, so no two backends can answer differently. A
   `TextRun`'s `rect.width` already carries the advance in cells; the gap is that
   `measure` remains a second, independently answerable source of truth on every
   conforming canvas.
4. **A total backend record with no-op fields is a third option for §2** — viable
   only for a seam narrow enough that every primitive degrades to nothing.
   `scrollbar` disqualifies ours, which argues that [F4](./comparison.md)'s
   "decide where the lowering lives" is the prior question, not a parallel one.
5. **Content-keyed memoization of measurement** (`memo ~eq:String.equal`) is a
   cheap, proven answer within F8's copy-or-arena discipline, distinct from
   Slint's item-keyed backend cache: the frame arena copies each run and dedupes
   nothing, so a repeated run pays segmentation every frame. Segmentation is our
   expensive step too (`cellsOf`).
6. **Reject the no-sub-cell option knowingly.** A cell toolkit can refuse to
   address below the cell and lose nothing, so `RuleEdge`'s cost is attributable
   to Skia sharing the seam rather than to cell geometry — evidence for the
   umbrella's open question, on the side of two seams.
7. **Do not import the tree-not-DAG cost.** Our display list is flat and linear,
   which sidesteps it; any move toward a retained composition tree must answer it.

## Sources

- [`src/notty.mli`][mli] — the interface: `A`, `I`, the stated monoid laws,
  `Cap`, `Render`, and the Basics / Limitations / Performance-model sections.
- [`src/notty.ml`][ml] — `Text` (segmentation and width), `A` (packed
  attributes), `I` (the image variant and smart constructors), `Operation` (the
  per-row lowering), `Cap` (`ansi` / `dumb`), `Render`, `Tmachine`.
- [`src-unix/notty_unix.mli`][unix-mli] / [`src-unix/notty_unix.ml`][unix-ml] —
  `Term`, `output_image_size`, `cap_for_fd`.
- [`src/no-uucp/README.md`][nouucp-readme] and
  [`src/no-uucp/notty_uucp.mli`][uucp-mli] — the vendored `Uucp`/`Uuseg` subset.
- [`README.md`][repo-readme] — positioning and the Vty lineage;
  [`CHANGES.md`][changes] — the Unicode 13 pin and the flicker-free change;
  [`notty.opam`][opam] — license and dependencies.

Revision pinned with `gh api repos/pqwy/notty/commits/master --jq .sha`; every
cited path fetched from `raw.githubusercontent.com` at that SHA.

<!-- References -->

[rev]: https://github.com/pqwy/notty/tree/e035d069370da436f1fc53525c1e16bff3ed687e
[repo]: https://github.com/pqwy/notty
[repo-readme]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/README.md
[readme-what]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/README.md#L66
[readme-vty]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/README.md#L21
[readme-tests]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/README.md#L29
[mli]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli
[ml]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml
[mli-intro]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L9
[mli-comp]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L229
[mli-beside]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L237
[mli-above]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L253
[mli-over]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L268
[mli-void]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L225
[mli-equal]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L186
[mli-attr-cat]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L156
[mli-cap]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L408
[mli-render]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L425
[mli-private]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L609
[mli-cwidth]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L700
[mli-stretch]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L833
[mli-perf]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.mli#L876
[img-type]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L232
[img-width]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L244
[img-height]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L254
[img-equal]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L264
[img-hcat-op]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L281
[img-void]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L305
[concatm]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L19
[linspcm]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L25
[memo]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L30
[hcat]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L338
[tabulate]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L351
[chars]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L355
[hsnap]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L362
[graphemes]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L92
[text-sub]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L121
[text-tobuffer]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L111
[of-unicode]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L143
[attr-type]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L164
[attr-tag]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L189
[attr-cat]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L219
[op-type]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L428
[scan-crop]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L478
[cap-type]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L490
[cap-ansi]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L540
[cap-dumb]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L555
[render-line]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L586
[refresh]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/notty.ml#L886
[unix-mli]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src-unix/notty_unix.mli
[unix-ml]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src-unix/notty_unix.ml
[mli-unix-size]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src-unix/notty_unix.mli#L160
[capforfd]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src-unix/notty_unix.ml#L20
[nouucp]: https://github.com/pqwy/notty/tree/e035d069370da436f1fc53525c1e16bff3ed687e/src/no-uucp
[nouucp-readme]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/no-uucp/README.md
[uucp-mli]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/src/no-uucp/notty_uucp.mli
[changes]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/CHANGES.md
[opam]: https://github.com/pqwy/notty/blob/e035d069370da436f1fc53525c1e16bff3ed687e/notty.opam
[vty]: https://hackage.haskell.org/package/vty
