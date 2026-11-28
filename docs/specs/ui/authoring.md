---
status: draft
owner: sparkles:ui
reviewed: 2026-11-26
---

# `sparkles:ui` component authoring — Feature Requirements (`AUT`)

## Abstract

`sparkles:ui` components are ordinary D functions that build the frame's
element tree as one nested expression that reads like a Flutter widget tree or
JSX. A component is a pure function of the application's state, called every
frame, and a retained store beneath it keeps what must outlive a frame:
scroll offsets, focus, measured sizes. Apart from raster images and
paint-only drawing leaves, every element is a box or a run of text; a toggle,
a scroll view or a calendar is a composition of the two that
declares its own semantics, and a widget with an unusual geometry brings its
own measure-and-arrange layout as plain data. Building a frame allocates no
garbage-collected memory, and every element has an identity that survives
the conditionals around it.

## Introduction

An interactive application redraws its interface whenever its state
changes, and the interface it draws should be a function of that state and
nothing else. Immediate-mode toolkits give the author exactly that: a view is
a function called every frame, with no widget objects to create, update or
destroy. Large views still need retained structure underneath: a measure
cache, a height index for virtual lists, and a store of per-element
presentation state. Floating surfaces need more. The toolkit's
[overlay layer](./popup.md), which places menus and tooltips, needs every
element to have a stable name, a resolved clip and a defined paint order.

A function-shaped API in D leaves two questions open. The first is build
order: D evaluates arguments before the call, so a child written inside its
parent's argument list is built before the parent exists. It cannot see the
parent's context, such as density, a disabled flag, or the function that
lifts the subtree's messages into its parent's message type. The second is
the vocabulary: a toolkit that makes each widget a core element kind
multiplies the dispatch sites every backend must handle, and leaves an
application's own widgets second-class next to the library's.

This specification answers both with one model. Children are D lazy
variadic arguments, so a parent opens, sets its context, evaluates its
children in order and closes, as [Clay](../../research/ui-layout/clay.md)'s
element macro does, while the author still writes one expression. An
element's [identity](../../glossary.md#element-identity) is its parent's
identity mixed with its argument position, and with its key in a keyed list.
A conditional that builds nothing still occupies its argument position, so
its siblings keep their identities either way. The element vocabulary is
closed and small: a box and a text run, plus raster images and paint-only
leaves. A widget is a composite of those that declares a role, a checked
state and focusability. A custom geometry is a
[layout protocol](../../glossary.md#layout-protocol): plain-data parameters
with a static measure and arrange, which the core calls inside its single
layout pass, measuring each child once.

The page specifies the component model, the authoring surface, identity,
the build and the per-element records it writes, the primitive set, the
layout protocol, and the obligations the overlay layer places on all of
them. It does not specify layout's sizing algorithm, which
[layout.md](./layout.md) owns, the anchored-overlay policy, which
[popup.md](./popup.md) owns, the theme, input decoding or any backend; nor
native platform widgets, whose substitution behind a role is an open
question. The evidence is the
[component-authoring study](../../research/ui-authoring/index.md), whose
decisions UI-Q1 to UI-Q8 this page turns into requirements: §1 lists the
invariants, §2–§9 the requirements by area, §10 the alignment, side and axis
types still being unified, §11 the toolchain requirement, §12 what
supersedes older specs, §13 the acceptance scenarios, §14 each
requirement's status and evidence, §15 delivery, and §16 the open
questions.

## 1. The contract at a glance

1. **A component is a pure function.** It reads its arguments, the builder's
   context and last frame's element store, and nothing else; equal inputs
   build equal trees.
2. **The tree is built once per frame, top-down, in pre-order.** A parent
   opens before its children run and closes after them; no element is added
   once the root closes.
3. **Identity is positional.** An element's identity is fixed by its argument
   path from the root and, in a keyed list, its key. A conditional that
   builds nothing keeps its slot.
4. **Handlers are data.** An event handler is a message value; a closure
   never survives the frame.
5. **The core knows four element kinds**: box, text, image and paint-only
   custom. Every widget is a composite of them.
6. **A custom layout is data plus two static functions.** It runs inside the
   one layout pass and measures each child once.
7. **Building allocates no garbage-collected memory**, and every capacity it
   fills is a stated bound.

## 2. Components and state (UI-Q1, UI-Q4, UI-Q5)

**AUT1: Components are pure.** A component **must** be a function taking the
frame builder by `ref` and its inputs by value or `in`, returning the handle
of the element it built, and **must** be `@safe pure nothrow @nogc`. Its
output **must** depend only on its arguments, the context the builder exposes
and the element store as last frame committed it. Building a frame twice from
equal inputs **must** produce trees whose pre-order sequence of identity,
kind, configuration and text is equal.

_Rationale:_ Purity is what lets a host skip, replay or memoise a component
without changing what the user sees, and what lets a test assert a whole
interface as data.

**AUT2: Cells are read at the edges.** A component **must not** subscribe to,
read or write a reactive cell. The host reads the application's cells before
the build and passes the values in as `const` arguments.

**AUT3: Memoisation never changes output.** A memo site **must** be keyed by
the memoised function, its arguments and the builder context in force, and
**must** accept only a `pure` function. A frame built with any memo site
answered from its cache **must** equal, by the comparison of `AUT1`, the
frame built with every memo site evaluated.

**AUT4: Lifecycle is a set difference.** An element is _mounted_ in the frame
whose tree first holds its identity and _unmounted_ in the first frame whose
tree no longer holds it. The toolkit **must** derive both as the difference
between consecutive frames' identity sets, and **must not** offer mount or
unmount callbacks to components.

**AUT5: Handlers yield messages.** An event attribute **must** take a message
reference made by `ui.on` from a value of plain-old-data type, or from a
function of the event's payload to such a value. The value **must** be copied
into the frame's storage; a message reference **must not** hold a delegate or
any pointer into the component's stack. A message type that is not plain data
**must** fail to compile.

**AUT6: Lifting messages, checked where they are sent.** `ui.mapMsg!fn`
**must** lift every message its subtree sends through `fn` into the enclosing
scope's type. In a debug build, `ui.on` **must** compare the type it sends
with the innermost open `mapMsg` scope's expected type and report a mismatch
against the sending element, as `messageTypeMismatch`; a `mapMsg` whose
target type differs from its own scope's **must** be reported as
`mapMsgTargetMismatch`.

**AUT7: Dispatch runs against the last painted frame.** An input event
**must** be resolved to a message against the tree, layout and hit targets of
the frame last painted, never against a frame still being built.

_Rationale:_ The user aimed at what was on the screen. The
[overlay layer](./popup.md) relies on this ordering for its one-frame
outside-press exemption (`DSM9`) and for stable placement (`PLC13`).

**AUT8: State lives in two places, and neither is a hook.** Domain state
**must** live in the application and reach components only as arguments.
Presentation state — scroll offsets, carets, focus, hover, animation phase,
last frame's measured size — **must** live in an element store keyed by
identity. A component **may** read the store entry of the element it is about
to open, and of any identity it can name; it **must not** write the store. The
host commits the store after layout. No state **may** be addressed by the
order of calls within a component.

## 3. The authoring surface (UI-Q2, UI-Q7)

**AUT9: Attributes are named only.** Every builder primitive and library
component **must** begin its attribute list with a `NamedOnly` sentinel
parameter, so passing an attribute positionally fails to compile.

**AUT10: Children are named and last.** A primitive or component that takes
children **must** place a second `NamedOnly` sentinel immediately before the
children parameter and **must** name that parameter `children`, so a
positional argument after the last attribute fails to compile instead of
silently becoming a child.

**AUT11: Children are lazy.** A children parameter **must** be a `scope` lazy
variadic array of `Node delegate() @safe pure nothrow @nogc`. The callee
**must** evaluate each child delegate exactly once, in argument order, after
its own element has opened and before it closes. Evaluating the children
**must not** allocate a closure in the caller; this depends on the toolchain
requirement `AUT50`.

**AUT12: An empty child keeps its slot.** `Node.none` **must** be accepted
wherever a child is, **must** add no element, and **must** still consume its
argument position, so every later sibling's identity is the same whether a
conditional yields a node or `Node.none`.

**AUT13: Lists.** A range **must** become children through
`toUi(ui).mapKeyed!(key, row)` or `toUi(ui).mapByIndex!(row)`. Either
**must** occupy the one argument position it is written in and splice its rows
into the parent's children, so for layout and semantics the rows are the
parent's own children.

**AUT14: Text is interned.** `ui.text` **must** accept a string or an
interpolated expression sequence, and **must** copy the text into the
frame's text pool without garbage-collected allocation. An element's text
**must** remain valid until the frame is discarded, whatever the lifetime of
the slice it was built from.

**AUT15: A subtree as a value is a `scope` delegate.** A component that takes
a subtree from its caller, such as a card's content, **must** take it as a
`scope` child delegate and build it where it places it, under that place's
context and with that place's identity. The toolkit **must not** offer value
forms of composites, deferred placement, or an argument arena for them.

**AUT16: Context flows down.** The builder **must** expose a context —
density, the disabled flag, the open `mapMsg` scope, and environment
overrides — that an element's children see once it has opened. An attribute
expression **must** be evaluated in the context of the slot the element sits
in, because it runs before the element opens. Closing an element **must**
restore the context in force before it opened.

**AUT17: Misplaced elements are reported.** In a debug build, an element
built outside any child slot that takes a later slot **must** be reported as
`slotAlreadyTaken`, and a child delegate that returns an element built before
it ran **must** be reported as `childBuiltOutsideSlot`. A release build
**may** omit both checks.

_Rationale:_ A `Node` expression assigned to a local in a view body builds
immediately, under whatever element is open, and type-checks. The two
diagnostics are the only defence the lazy surface has against it.

## 4. Identity (UI-Q7)

**AUT18: Positional identity.** Every element **must** have a 64-bit identity
computed as a mix of its parent's identity and its argument position, and, for
a row of a keyed list, additionally of its key. The root's identity is fixed.
The identity **must not** depend on source location, call order outside the
element's own argument path, or the number of elements built before it.

_Rationale:_ Clay's 32-bit hash of sibling index and parent identity
collided 88 times among 114 684 elements in one frame and renumbers every
sibling after an insertion. Argument positions do neither.

**AUT19: Identity is unique within a frame.** No two elements of one frame
**may** share an identity. Two rows of one keyed list with equal keys
**must** be reported as a duplicate key with the list's identity, and the
store and overlay lookups **must** treat that identity as ambiguous rather
than resolve it to either element.

**AUT20: Identity is stable across frames.** An element built at the same
argument path, with the same key where it is keyed, **must** have the same
identity in every frame, whatever its siblings' conditionals and whatever
rows were inserted or removed before it in its keyed list.

## 5. The build and its records (UI-Q7)

**AUT21: One top-down build per frame.** A frame's elements **must** be built
in one pass that opens each element, evaluates its children and closes it,
so that element order in the frame's tables is pre-order. No element **may**
be added after the root closes; in particular, no element's children **may**
be built during layout.

_Rationale:_ Building during layout, as Flutter's `LayoutBuilder` does,
breaks pre-order, hides the deferred subtree from memoisation and from any
sweep in element order, and forces the context to be restored by hand.

**AUT22: A children stack, not linked records.** When an element closes, the
builder **must** compute its [fit size](../../glossary.md#fit-size) from its children's contiguous run on
a [children stack](../../glossary.md#children-stack), copy the run into the frame's children table, and pop it.
Closing an element **must not** update the record of any element other than
the one closing.

**AUT23: Fit size at close.** An element whose size on an axis is `fit`
**must** have its fit size on that axis computed when it closes, from its
children's fit sizes, gaps and padding, without a separate bottom-up pass.
The word _fit_ is reserved for this size to content, `Sizing.fit`.

**AUT24: The build allocates nothing from the garbage collector.** Every
builder primitive, library component and memo site **must** be
`@safe pure nothrow @nogc`. In steady state, a frame whose element count does
not exceed the previous frame's **must** make no heap allocation at all: the
frame's tables are reused.

**AUT25: Capacities are stated, and overflow is reported.** Every bounded
table the build or layout fills **must** have a stated capacity, and filling
one past it **must** be reported to the host as a value it can read after
the frame. It **must not** be an assertion failure or silent truncation.
How the report reaches the host is open question UI-Q12.

## 6. The primitive set (UI-Q8)

**AUT26: Four element kinds.** The core **must** have exactly four element
kinds: `box`, `text`, `image` and `custom`. No widget — toggle, button, text
field, scroll view, list, scrollbar — **may** be a core kind. A library
widget and an application's widget **must** be built from the same
primitives through the same public API.

_Rationale:_ Each widget kind the prototype kept in the core cost a dozen
dispatch sites, which is how adding a kind silently skips a backend, and
measured no faster per element than its composite.

**AUT27: `box` carries configuration, not behaviour.** `box` **must** accept,
as named attributes, its layout (direction `column`, `row` or `stack`; gap;
padding; `fit`, `grow`, `fixed` or `percent` sizing per axis; alignment per
axis), clip and scroll per axis, floating placement, border, a background
slot, semantics (`AUT29`), a label, a press message, a custom layout
(`AUT33`), per-child layout data for its parent's layout, environment
overrides and the disabled flag. Its sizing **must** follow
[layout.md](./layout.md)'s vocabulary and integer rules.

**AUT28: `text` is the one measured leaf.** `text` **must** be the only kind
whose fit size comes from measuring content. It **must** wrap to the width
layout gives it, and **may** carry a caret position for an editable field.

**AUT29: Semantics are declared.** A box **must** be able to declare a role,
a checked state, a value, whether it is focusable, and whether it merges its
descendants' text into its own label. A composite widget that declares them
**must** yield the same semantics tree — role, label, checked state, value,
focusability and press target per node — as a core kind with the same
meaning would.

**AUT30: A press bubbles to its handler.** A hit **must** land on the deepest
element whose rect contains the point, after clipping, and the press
**must** be delivered to the nearest ancestor-or-self that carries a press
message.

**AUT31: Focus order is tree order.** The focus order **must** be the
pre-order of elements that declare themselves focusable.

**AUT32: Images and paint-only leaves are escape hatches.** `image` **must**
take a raster handle, a size and alternative text, and present the role
`image`. `custom` **must** take a painter (`AUT39`), a size and its own
semantics.

## 7. Custom layouts (UI-Q8)

**AUT33: The layout protocol.** A box **must** accept `custom:
ui.layout(params)`, where the type of `params` is plain old data with a
static `arrange(in P, Size inner, scope Child[] kids, scope ref LayoutCtx
ctx)` and, optionally, a static `measure(in P, Constraints c, scope
const(Child)[] kids)` returning a size. A params type that is not plain data,
or that lacks `arrange`, **must** fail to compile. Without `measure`, the box
**must** take the size its parent's constraints give it.

**AUT34: A layout is data.** `ui.layout` **must** copy the params into the
frame's storage and record two function pointers. A custom layout **must
not** capture a closure, and **must** be `@safe pure nothrow @nogc`.

**AUT35: Each child is measured once.** `arrange` **must** receive each
child's fit size and layout data, and **must** write each child's position
relative to the content box and, optionally, its size, which defaults to the
fit size. The core **must** then lay out each child's subtree at the size
`arrange` gave it. `measure` and `arrange` **must not** be able to rebuild,
add or remove a child.

**AUT36: What `arrange` may ask.** The context **must** offer the height a
child needs at a given width, and scratch storage valid until `arrange`
returns. It **must not** offer the element store, the text pool or the
builder.

**AUT37: When `measure` runs.** `measure` **must** run when the box closes,
for each axis that is `fit`, with unbounded constraints, and again during
layout with the width its parent allocated, so a custom layout's height can
depend on its width as text's does.

**AUT38: A custom layout's children are ordinary elements.** Children of a
box with a custom layout **must** keep positional and keyed identity, hit
testing, press routing, semantics, focus order and memoisation exactly as
the children of a built-in direction do.

**AUT39: Paint-only leaves.** A [paint-only leaf](../../glossary.md#paint-only-leaf), `ui.custom(paint: ui.painter(params))`, **must**
accept plain-data params with a static `paint(in P, Rect r, ref DrawList
list)`, and the painter **must** emit only draw commands within `r`. The leaf
**must** be one element with one hit target and its own semantics; what it
paints **must** be invisible to hit testing and to the semantics tree.

**AUT40: Integer geometry.** Every coordinate and size `measure`, `arrange`
and `paint` receive or return **must** be an integer in cells,
as [layout.md](./layout.md) requires of the whole engine.

_Rationale:_ In `double`, `sin(π/6)` is `0.49999999999999994`, so a clock
label rounded from it lands a cell off. The prototype's clock uses an
integer table; a gauge with arbitrary angles needs a stated rounding rule.

Grids are not a custom layout: [layout.md](./layout.md)'s track sizer stays
built in. Anchored fractions, a built-in direction placing each child at a
fraction of the box, are permitted as a convenience but not required.

## 8. What the overlay layer needs (popup.md)

The [anchored-overlay specification](./popup.md) defines menus, tooltips,
popovers and dialogs as elements authored where they hang and emitted above
everything else. Each requirement below is the construction model's half of
a requirement there, cited in its title; popup.md keeps the policy.

**AUT41: A stable key per element (`ANC6`, `ANC7`).** The identity
of `AUT18`–`AUT20` **must** be the key an overlay's anchor, the overlay
arena's per-key lookup and the element store all use. A key that names two
elements in one frame **must** resolve as ambiguous, with a diagnostic and no
positional fallback.

_Rationale:_ popup.md calls frame-to-frame stability of a hit identity an
authoring convention. Positional identity makes it a property of the
construction model for every element that is not a keyed row, where the key
stays domain-derived.

**AUT42: A resolved clip per element (`ANC3`, `PLC15`, `DSM8`).** After
layout, every element **must** have the one clip rectangle it paints under,
the intersection of every clipping ancestor's clip. An anchor's verdict —
visible, clipped, hidden (laid out but scrolled away) or gone (not built) —
**must** be computable from the frame before placement runs.

**AUT43: Overlays are fitted, solved, then arranged (`LYR7`, `PLC3`,
`PLC9`, `PLC12`).** An overlay element **must** be excluded from its
parent's flow, so it neither grows nor moves the element it hangs off. Its
width **must** be its anchor's width when it covers the anchor, and
otherwise its own size resolved against the surface's width; its height
**must** be resolved against the boundary's height. The placement solve
**must** run once per frame, after the flow is laid out, against the
surface as the default boundary, and the overlay's subtree **must** then be
laid out in the rectangle the solve returned. An overlay nested in another
**must** be placed after the one it hangs off. When the solve narrows an
overlay, its content **must** keep the width it was laid out at and be cut by
the overlay's clip.

**AUT44: Emitted above the flow, in one order (`POP3`, `LYR1`, `LYR2`,
`LYR8`).** An overlay **must** be authored as a child of its anchor, and only
its emission moved: the display list **must** emit overlays after the flow,
outside every ancestor's clip, ordered by band and, within a band, by tree
order. A nested overlay **must** take the higher of its own band and its
parent's. The hit targets and key targets **must** list overlays in that same
order, after the flow, so the overlay painted last is the first to answer.

**AUT45: Closing overlays paint and take no input (`LYR10`).** An overlay
marked closing **must** still be emitted, and neither it nor any element
inside it **may** contribute a hit target or a key target, or be returned by
the arena's positional lookup.

**AUT46: The resolved side reaches the arrow (`PLC10`).** The placement's
resolved side and arrow cell **must** be recorded on the overlay's frame
entry, and the display list **must** draw the overlay's arrow on the edge
facing that side.

**AUT47: Open is membership (`LYR9`).** An overlay **must** be open in a
frame exactly when it is built in that frame, visible, and its anchor is not
hidden. A component closes an overlay by not building it; there is no
visibility flag for it to forget.

**AUT48: At most 16 overlays (`POP7`).** A frame **must** hold at most 16
open overlays. An overlay past the 16th **must** be absent from the arena,
from paint and from hit and key targets, and the arena **must** report that
it overflowed.

## 9. Deferred: the layout record's shape

How the per-element layout fields are stored — one record, a hot/cold split,
or one array per field — is deliberately not specified. The split measured
1.3–1.9× faster in a placement sweep and at most 1 ns per element slower to
build; one array per field measured slower than the split. It is decided by
re-measuring once `libs/ui` builds its frames this way, because the real
layout passes may differ from the ones the experiments modelled. No
requirement here **may** be read as fixing the record layout.

## 10. Shared vocabulary (proposed)

**AUT49: One spelling for alignment, sides and axes.** The toolkit, its
overlay layer and `sparkles:base`'s text-width module **should** share these
types, proposed and not yet accepted:

| Type           | Members                          | Replaces                                                                     |
| -------------- | -------------------------------- | ---------------------------------------------------------------------------- |
| `Align`        | `start`, `center`, `end`         | `sparkles.ui.widget.Alignment`, `sparkles.ui.overlay.place.Align`            |
| `Side`         | `top`, `bottom`, `left`, `right` | `sparkles.ui.overlay.place.Side`                                             |
| `Axis`         | `x`, `y`                         | any `horizontal`/`vertical` spelling                                         |
| `PlaceVerdict` | `fits`, `adjusted`, `refused`    | `sparkles.ui.overlay.place.Fit`, renamed because _fit_ is reserved (`AUT23`) |

`Align` and `Axis`, and probably `Side`, would live in `sparkles:base`,
because `sparkles.base.text.width` needs them and `sparkles:base` cannot
import `sparkles:ui`; `sparkles.ui.geometry` would re-export them. The
exception policy for **should**: a type whose meaning genuinely differs, such
as text-field alignment's `decimal`, keeps its own name. Whether
`sparkles.base.text.width`'s `Align` adopts `start`/`end` or keeps
`left`/`right` is part of the same open unification.

## 11. Toolchain requirement

**AUT50: `scope` lazy variadics allocate no closure.** Every compiler that
builds `sparkles:ui` **must** compile a `scope` lazy variadic array of
delegates without allocating a closure in the caller, so views with child
slots compile under `@nogc`. Stock DMD 2.115 and LDC 1.43 reject every such
view. The fix is [dlang/dmd#22885](https://github.com/dlang/dmd/issues/22885),
carried by the sparkles DMD and LDC forks as UD8 and UL20 in the toolchain's
upstreaming plan (`docs/specs/toolchain/upstreaming.md` on branch
`build/scope-lazy-variadic-toolchain`), and delivered to the flake by pull
request `#773`. No `AUT` requirement that depends on `AUT11` **may** be
implemented in `libs/ui` before that toolchain is the repository's.

## 12. What this page supersedes

Where an older requirement says otherwise, this page decides. Each older
page carries a pointer here; none is rewritten.

| Older text                                                                                                     | Superseded by    | What changes                                                                                                                              |
| -------------------------------------------------------------------------------------------------------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| [`WGT2`](./widgets.md): a view is `view(model, ctx) → WidgetTree`                                              | `AUT1`, `AUT15`  | A component builds into the frame's builder and returns a handle; a subtree is embedded as a `scope` delegate, not as another view's tree |
| [`WGT3`](./widgets.md), [`PRN12`](./principles.md), [`UI-O2`](./open-issues.md#ui-o2): a sum over widget kinds | `AUT26`, `AUT27` | The closed sum is over four primitives; widget variety is configuration and composition                                                   |
| [`WGT5`](./widgets.md): a widget _may_ carry a key                                                             | `AUT18`–`AUT20`  | Every element has an identity; a key is needed only in a keyed list                                                                       |
| [`WGT7`](./widgets.md), [`WGT8`](./widgets.md): containers and primitives as kinds                             | `AUT26`, `AUT27` | `row`, `column`, `stack` and `panel` are `box` configurations; `glyph` and `rich` are `text`; `line` is paint                             |
| [`WGT10`](./widgets.md): a scrollbar kind                                                                      | `AUT26`, `AUT32` | A scrollbar is a composite or a `custom` leaf with semantics                                                                              |
| [`LAY1`](./layout.md): four separate passes                                                                    | `AUT23`          | The bottom-up width measure is fused into the build; layout stays `O(n)`                                                                  |
| The research study's UI-Q6: value forms and deferred placement                                                 | `AUT15`          | Removed, as UI-Q7 records                                                                                                                 |

`AUT33` does not reopen [layout.md](./layout.md)'s exclusions: the core
still has no constraint solver and no box wrapping. A custom layout may
implement a flow or a wrap for its own children; the built-in directions do
not.

## 13. Acceptance scenarios

Each scenario names its oracle. "By hand" means expected values derived on
paper, independently of the implementation; the prototype's tests use the
same derivations.

| Scenario                                                                                                                                     | Requirements              | Oracle                                                                                     |
| -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------ |
| Build the Stats pane twice from equal state; compare pre-order (identity, kind, configuration, text)                                         | `AUT1`                    | Equality of the two sequences                                                              |
| Build a pane with every memo site forced to evaluate, and again answered from the cache                                                      | `AUT3`                    | Equality of the two sequences                                                              |
| Toggle a conditional child between a node and `Node.none`; record every later sibling's identity                                             | `AUT12`, `AUT18`, `AUT20` | The identities are unchanged                                                               |
| Remove the first of five keyed rows                                                                                                          | `AUT20`, `AUT4`           | The four survivors keep their identities; the set difference names one unmounted element   |
| Two keyed rows with equal keys                                                                                                               | `AUT19`, `AUT41`          | A duplicate-key report; an overlay keyed to it resolves as ambiguous                       |
| A compact column holding a pane whose gap reads the density                                                                                  | `AUT16`                   | The pane is built compact; the dump shows `[compact]`                                      |
| Assign a node to a local in a view body, then place it; and a node built before its slot ran                                                 | `AUT17`                   | `slotAlreadyTaken`, `childBuiltOutsideSlot` in a debug build                               |
| Send a message of the wrong type under a `mapMsg`                                                                                            | `AUT6`                    | `messageTypeMismatch` names the sending element                                            |
| Compile a component taking an attribute positionally, a positional child after the attributes, and a message holding a delegate              | `AUT5`, `AUT9`, `AUT10`   | Each fails to compile                                                                      |
| Run a frame twice at equal size under an allocation counter                                                                                  | `AUT24`                   | The second frame makes no heap allocation                                                  |
| Fill each bounded table one past its capacity                                                                                                | `AUT25`, `AUT48`          | An overflow report readable after the frame; no assertion failure                          |
| The settings page built from composite widgets: its semantics tree against a hand-written expectation; a press on a toggle's knob; Tab order | `AUT29`–`AUT31`           | The hand-written tree; the press reaches the toggle's message; 20 stops in tree order      |
| A 21 × 21 clock face in the layout protocol                                                                                                  | `AUT33`–`AUT35`, `AUT40`  | The twelve label positions worked by hand (12 at 9,1; 3 at 19,10; 6 at 10,19; 9 at 1,10)   |
| A timeline whose 10-cell label pushes a later event into the next lane; a press on the label's tail                                          | `AUT35`, `AUT37`, `AUT38` | Every rect by hand; the press reaches that event's message                                 |
| A week calendar with overlapping events; remove an earlier event                                                                             | `AUT35`, `AUT38`          | Column rects by hand; identities unchanged                                                 |
| A paint-only clock face                                                                                                                      | `AUT39`                   | One element, one hit target; its draw commands lie within its rect                         |
| A menu under a button in a scrolled viewport: scroll the button out, back in, and to the viewport's edge                                     | `AUT42`, `AUT43`, `AUT47` | popup.md's overlay tests (`sparkles.ui.overlay.arena`), rerun unchanged on the new builder |
| Two overlapping overlays in different bands, one nested; one closing; seventeen open                                                         | `AUT44`, `AUT45`, `AUT48` | The same tests: paint order, hit order, no hits from the closing one, `overflowed` set     |
| An overlay with an arrow that flips sides                                                                                                    | `AUT46`                   | The arrow on the edge facing the resolved side                                             |
| Compile a view with a child slot under `@nogc` on stock and on fixed compilers                                                               | `AUT50`                   | Stock: the closure error; fixed: compiles                                                  |

## 14. Requirement status

No requirement is implemented in `libs/ui`. `planned` means the requirement
is decided and its evidence is a prototype; `proposed` means the requirement
itself awaits acceptance; `open` means it depends on a decision or a change
outside this page. Evidence is prototype evidence: it shows the requirement
is implementable, not that `sparkles:ui` conforms.

| ID           | Status   | Evidence                                                                                                                                                                                                                                                                                                                                                    |
| ------------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AUT1–AUT8    | planned  | [`ui-api-demo-lazy`](../../research/ui-authoring/experiments/ui-api-demo-lazy/README.md) (`app.d`, `ui_sketch.d`: `mapMsg`, `memo`, `ui.on`; `out/bad-ldc.txt` for `AUT6`); [`ui-primitives`](../../research/ui-authoring/experiments/ui-primitives/README.md) (`peekState`, `commitStore`, `dispatch`); no set-difference lifecycle or equality oracle yet |
| AUT9–AUT17   | planned  | `ui-api-demo-lazy`: `out/app-ldc.txt` (the compact pane, argument positions kept, `slotAlreadyTaken` and `childBuiltOutsideSlot` reported), `out/bad-ldc.txt` (`messageTypeMismatch` at the sending element)                                                                                                                                                |
| AUT18, AUT20 | planned  | `ui-api-demo-lazy/ui_sketch.d` (`mix(parent id, position [, key])`); `ui-primitives` `layouts.calendar.keyedIdentity`                                                                                                                                                                                                                                       |
| AUT19        | planned  | Not prototyped: no experiment detects duplicate keys                                                                                                                                                                                                                                                                                                        |
| AUT21–AUT24  | planned  | [`lazystack.d`](../../research/ui-authoring/experiments/ui-api-demo-lazy/bench/src/lazystack.d); [build cost](../../research/ui-authoring/index.md#build-cost) and [the fit pass](../../research/ui-authoring/index.md#the-fit-pass); every prototype view is `@safe pure nothrow @nogc`                                                                    |
| AUT25        | open     | UI-Q12                                                                                                                                                                                                                                                                                                                                                      |
| AUT26–AUT32  | planned  | `ui-primitives`: `primitives.settings.sameSemantics`, `findToggleAndPress`, `focusOrder`, `scrollViewScrollsAndClips`; [pure against hybrid](../../research/ui-authoring/index.md#primitives-and-custom-layouts-ui-q8)                                                                                                                                      |
| AUT33–AUT40  | planned  | `ui-primitives` `src/layouts.d`: `layouts.clock.protocol`, `layouts.clock.paintOnly`, `layouts.timeline.lanes`, `layouts.calendar.overlapColumns`                                                                                                                                                                                                           |
| AUT41–AUT48  | planned  | The obligations hold on the shipped tree builder (`sparkles.ui.overlay.arena` tests, popup.md `POP7`, `LYR1`, `LYR9`, `LYR10`, `PLC10`); not yet on the lazy builder                                                                                                                                                                                        |
| AUT49        | proposed | The enum unification is in progress elsewhere                                                                                                                                                                                                                                                                                                               |
| AUT50        | open     | `ui-primitives/out/stock-compilers.txt`, `ui-api-demo-lazy/out/stock-ldc.txt`; toolchain pull request `#773`                                                                                                                                                                                                                                                |

## 15. Delivery

Delivery order, coarse beyond the first slice. Each slice keeps `libs/ui`
green and its existing consumers building.

| Slice | Scope                                                                                                                        | Requirements         | Gate                                                                 |
| ----- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------- | -------------------------------------------------------------------- |
| A0    | This specification and its evidence                                                                                          | all                  | Owner review                                                         |
| A1    | The fixed toolchain becomes the repository's                                                                                 | `AUT50`              | Pull request `#773` merged                                           |
| A2    | The builder core beside the existing tree builder: lazy children, identity, children stack, text pool, messages, store reads | `AUT1`–`AUT24`       | §13's build and identity scenarios as tests in `libs/ui`             |
| A3    | Primitives, semantics, press routing and focus order                                                                         | `AUT26`–`AUT32`      | The settings-page scenarios                                          |
| A4    | The layout protocol and paint-only leaves                                                                                    | `AUT33`–`AUT40`      | The clock, timeline and calendar scenarios                           |
| A5    | Overlays on the new builder                                                                                                  | `AUT41`–`AUT48`      | The overlay layer's tests unchanged                                  |
| A6    | Components and applications move to the new builder ([migration.md](./migration.md)); the layout record's shape is decided   | `AUT25`, `AUT49`, §9 | The existing per-backend goldens unchanged; the split re-benchmarked |

## 16. Open questions

| Id     | Question                                                                                                                                                                                                                                                 | Affects                  | Decided before |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ | -------------- |
| UI-Q9  | How does a component read last frame's results — layout rects, scroll extent, hover — beyond the element store's committed fields, and which of them may decide what it builds? A virtual list needs only its viewport and offset; others may need more. | `AUT7`, `AUT8`           | A3             |
| UI-Q10 | How does an element removed this frame keep painting through an exit animation? `AUT4` unmounts it and `AUT47` closes an overlay that is not built, so an exit needs a retained snapshot or a closing state the store drives.                            | `AUT4`, `AUT45`, `AUT47` | A5             |
| UI-Q11 | Culling and draw-command identity: does the display list skip elements outside every clip, and does each draw command carry its element's identity so a backend can diff or cache by it?                                                                 | `AUT21`, `AUT42`         | A5             |
| UI-Q12 | Fixed capacities with an error handler: which tables are fixed, what their capacities are, and whether overflow goes to a host-supplied handler, a frame result or both.                                                                                 | `AUT25`, `AUT48`         | A2             |

The primitives prototype leaves narrower questions for slices A3 and A4 —
carrying state from `measure` to `arrange` or caching measures (`LAY13`),
relaying a child out at another width, sorted-input contracts for layouts,
whether merged semantics concatenate labels, and how a backend substitutes a
native control behind a role — listed in its
[README](../../research/ui-authoring/experiments/ui-primitives/README.md#open-questions).

## Relationship to existing specs

| Piece                                                             | Role                                                                                                                         |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| [Component-authoring study](../../research/ui-authoring/index.md) | The evidence and the decisions UI-Q1–UI-Q8                                                                                   |
| [layout.md](./layout.md) `LAY`                                    | The sizing vocabulary, integer units and track sizer the primitives and protocol use                                         |
| [popup.md](./popup.md)                                            | The overlay policy whose construction-side obligations §8 carries                                                            |
| [widgets.md](./widgets.md) `WGT`                                  | The component catalog, rebuilt from the primitives; `WGT2`, `WGT3`, `WGT5`, `WGT7`, `WGT8`, `WGT10` superseded in part (§12) |
| [principles.md](./principles.md) `PRN`                            | Regular values (`PRN6`) for messages and layout params; the closed sum (`PRN12`), now over primitives                        |
| [migration.md](./migration.md) `MIG`                              | Moving the components and hue onto the toolkit, which slice A6 joins                                                         |

→ [Overview](./index.md) · [Layout](./layout.md) · [Widgets](./widgets.md) · [Anchored overlays](./popup.md)
