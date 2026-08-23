# Mosaic — the layer above the seam ported, the seam itself deleted

**Category:** cross-target — shared layer above, replaced seam below.
**Last reviewed:** August 23, 2026. Pinned at [`ac3051d1`][rev].

Mosaic runs Jetpack Compose's compiler plugin and reactive runtime — the real
`androidx.compose.runtime` artifact, not a reimplementation — over a terminal
cell grid. It is on this list because it performs the experiment the umbrella's
[open question](./index.md#open-question-the-survey-may-not-settle) asks about,
and reports a clean result: **everything above the drawing seam transferred
unchanged; nothing at or below it did.**

| Attribute            | Value                                                                                                                                                      |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language             | Kotlin (Multiplatform: JVM, Linux, macOS, MinGW)                                                                                                           |
| License              | Apache 2.0                                                                                                                                                 |
| Repository           | <https://github.com/JakeWharton/mosaic>                                                                                                                    |
| Documentation        | <https://jakewharton.github.io/mosaic/docs/0.x/>                                                                                                           |
| Category             | cross-target — shared layer above, replaced seam below                                                                                                     |
| Pinned revision      | [`ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9`][rev] (`trunk`)                                                                                                |
| Target range         | **one** — a monospace terminal. No GPU target, ever                                                                                                        |
| Reused from upstream | `androidx.compose.runtime:runtime:1.12.0` + `androidx.lifecycle:lifecycle-runtime-compose` ([`libs.versions.toml`][libs], [`build.gradle`][runtimegradle]) |
| Not reused           | `androidx.compose.ui` — **absent from the dependency list**                                                                                                |
| Backends shipped     | one painter (`TextSurface`), two _encoders_ (`AnsiRendering`, `DebugRendering`)                                                                            |

> [!NOTE]
> [`docs/research/tui-libraries/mosaic.md`](../tui-libraries/mosaic.md) already
> covers Mosaic as a TUI toolkit — recomposition, the slot table, effects, the
> component set, and what a D port of the programming model would look like.
> This page reads the same tree for one thing only: where the renderer boundary
> is, and what crossed it.

## Overview

### What it solves

Terminal UI, written as Compose. `runMosaic` takes a `@Composable` lambda,
stands up a `Recomposer`, and prints a frame whenever composition, layout or
draw state changes ([`mosaic.kt`][mosaic]). No part of the reactive machinery
is Mosaic's: the compiler plugin, the slot table, `remember`, snapshot state
and the `Applier` protocol all come from the published Android artifact.

### Design philosophy

The README's FAQ states the thesis the whole project is a proof of:

> Compose is, at its core, a general-purpose compiler and runtime to do state
> tracking and tree node and property manipulation. This can be used on any
> platform supported by Kotlin for any kind of state or with any tree. […]
> Compose UI is the modern UI toolkit for Android which also runs on the
> desktop, iOS, and the web. The lack of differentiation between these two
> technologies has unfortunately caused Compose UI to overshadow the core under
> the single "Compose" moniker in an unforced marketing error.
>
> — [`README.md`][readme]

The dependency list is the falsifiable half of that claim, and it holds:
`mosaic-runtime` depends on `androidx.compose.runtime` and **not** on
`androidx.compose.ui` ([`mosaic-runtime/build.gradle`][runtimegradle]). The
line between "portable" and "not portable" is drawn exactly where the artifact
boundary is — and the drawing vocabulary is on the far side of it: Mosaic's
`DrawScope` is a file-level fork of Compose UI's, carrying the AOSP copyright
header and a replaced parameter list ([`layout/DrawScope.kt`][drawscope]).

## How it works

Three layers, with sharply different provenance.

**1. Composition — upstream, verbatim.** The only integration point is one
`Applier` subclass:

```kotlin
internal class MosaicNodeApplier(
	private val onChanges: () -> Unit = {},
) : AbstractApplier<MosaicNode>(root = MosaicNode(/* … */)) {
	override fun insertTopDown(index: Int, instance: MosaicNode) {
		// Ignored, we insert bottom-up.
	}
	override fun insertBottomUp(index: Int, instance: MosaicNode) {
		current.children.add(index, instance)
	}
	// remove / move / onClear are the same shape
}
```

— [`mosaic.kt`][mosaic]. Four list mutations over `MosaicNode.children` are the
entire surface Compose needs to drive an arbitrary tree, which is why the port
is cheap.

**2. Layout — Compose's _shape_, re-declared in cells.** `Measurable`,
`Placeable`, `MeasurePolicy`, `MeasureScope`, `MeasureResult`, `Constraints`,
`IntOffset`, `IntSize`, `Modifier` and `LayoutModifier` all exist, with Compose's
names and Compose's protocol — but in `com.jakewharton.mosaic.layout`, declared
fresh:

```kotlin
public interface Measurable : IntrinsicMeasurable {
	public fun measure(constraints: Constraints): Placeable
}

public abstract class Placeable {
	public abstract val width: Int
	public abstract val height: Int
	protected abstract fun placeAt(x: Int, y: Int)
}
```

— [`Measurable.kt`][measurable], [`Placeable.kt`][placeable]. Every dimension is
an `Int`, and the `Int` is a cell. The measure/place protocol survived the port;
its unit did not. Six files still carry the AOSP copyright header — `DrawScope`,
`ContentDrawScope`, `DrawModifier`, `LayoutModifier`, `Padding` and `modifier`
— marking them as forks rather than rewrites. A `MosaicNode` folds its
`Modifier` chain into a linked list of `MosaicNodeLayer`s (`LayoutLayer`,
`DrawLayer`, `KeyLayer`), each of whose three virtual methods — `doMeasure`,
`drawTo`, `sendKeyEvent` — defaults to delegating down the chain
([`layout/Node.kt`][layoutnode]).

**3. Painting — no seam at all.** This is the finding. The draw method's
signature is:

```kotlin
open fun drawTo(canvas: TextSurface) {
	next?.drawTo(canvas)
}
```

`TextSurface` is a **concrete `internal` class**, not an interface: a
`width * height` array of mutable `TextPixel`, each holding a code point, a
foreground, a background, a `TextStyle`, an underline style and an underline
color ([`surface.kt`][surface]). Nothing in Mosaic is polymorphic over where
drawing goes.

The one public drawing vocabulary, `DrawScope`, has exactly two operations:

```kotlin
public interface DrawScope {
	public val width: Int
	public val height: Int

	public fun drawRect(
		codePoint: Int = UnspecifiedCodePoint,
		foreground: Color = Color.Unspecified,
		background: Color = Color.Unspecified,
		textStyle: TextStyle = TextStyle.Unspecified,
		topLeft: IntOffset = IntOffset.Zero,
		size: IntSize = this.size.offsetSize(topLeft),
		drawStyle: DrawStyle = DrawStyle.Fill,
	)

	public fun drawText(
		row: Int, column: Int, string: String,
		foreground: Color = Color.Unspecified, /* + 4 more style defaults */
	)
	// + `Char` and `AnnotatedString` overloads
}
```

— [`layout/DrawScope.kt`][drawscope]. That file carries the AOSP header: it is
Compose UI's `DrawScope` with its vocabulary swapped out. `Paint`, `Brush`,
`Path`, `drawCircle`, `drawImage` and `Density` are gone; `codePoint`,
`TextStyle` and `UnderlineStyle` are in. It has one implementation,
`TextCanvasDrawScope`, and that implementation takes a `TextSurface` by
concrete type.

The **only** interface a caller can substitute is at the encoding step, one
level further out:

```kotlin
internal interface Rendering {
	fun render(mosaic: Mosaic): CharSequence
}
```

— [`rendering.kt`][rendering]. Two implementations: `AnsiRendering` (cursor
motion, stale-line clearing, synchronized-output brackets) and `DebugRendering`
(a node dump plus the frame). Both call `mosaic.draw()` and then ask the
resulting `TextCanvas` to serialize itself. The seam is over the **output
format**, not the drawing device.

## Q1 — measurement units, and who answers

Not on the painter, for the fourth consecutive subject — and the split is
sharper than Slint's, because there is no font abstraction to hide behind.
`Text` owns a `remember`ed `TextLayout` and its `MeasurePolicy` reads it:

```kotlin
val layout = remember { StringTextLayout() }
layout.value = value

Layout(
	measurePolicy = { layout.measure(); layout(layout.width, layout.height) },
	modifier = modifier.drawBehind { /* layout.lines.forEach { drawText(…) } */ },
)
```

— [`ui/Text.kt`][text]. And the measurement itself:

```kotlin
fun measure() {
	if (!dirty) return
	val lines = value.splitByLines()
	width = lines.maxOf { it.codePointCount(0, it.length) }
	height = lines.size
	this.lines = lines
	dirty = false
}
```

— [`text/TextLayout.kt`][textlayout]. **Width is a code-point count.** There is
no `wcwidth`, no East Asian Width table and no grapheme segmentation anywhere in
the tree; the only occurrence of "grapheme" in the repository is a `TODO` in the
terminal event parser ([`EventParser.kt`][eventparser]). A CJK character and a
combining acute are each one column. The seam does not merely
lack a unit for a proportional answer — it does not have the honest cell answer
either.

Two things follow for [friction §1][friction]. F1 is confirmed by a subject that
is terminal-only, which strengthens it: measurement is off the painter even
where there is one painter and no shaping to abstract. And Mosaic's more-correct
_layering_ coexists with a less-correct _answer_ — the `cellsOf` width that
`SkiaCanvas.measure` returns is a real Unicode width — so placement and
correctness are independent problems.

The residue of the port is visible in `Constraints`, whose surviving Compose
doc comment describes a range "in pixels" while every value in it is a cell
([`ui/unit/Constraints.kt`][constraints]). Nothing reads the comment, so
nothing corrected it.

## Q2 — is the contract stated in one place?

Two answers, at two different altitudes, and the split is instructive.

**At the painter: nothing to state.** `DrawScope` is total — every operation
works on every backend, because there is one backend. There are no optional
primitives, no `pushClip`/`popClip` pair (the word `clip` does not occur
anywhere in `mosaic-runtime`'s common sources), and no probing. A write outside
the surface is not clipped and not degraded; it fails a `check`:

```kotlin
operator fun get(row: Int, column: Int): TextPixel {
	val x = translationX + column
	val y = row + translationY
	check(x in 0 until width)
	check(y in 0 until height)
	return cells[y * width + x]
}
```

— [`surface.kt`][surface].

**At the device: thirteen named booleans, each with a spec link.**
`Terminal.Capabilities` declares `ansiLevel` plus twelve flags —
`cursorVisibility`, `focusEvents`, `inBandResizeEvents`, `synchronizedOutput`,
`themeEvents` and seven `kitty*` protocol flags — each documented with the VT
mode number or protocol URL it corresponds to
([`terminal/Terminal.kt`][terminalapi]). This is Qt's `hasFeature` model, stated
once, in a data type — precisely the declared floor
[F5](./comparison.md) describes.

But it is consumed **at the encode step, not the draw step**. Only three of the
thirteen reach rendering — `ansiLevel` and `kittyUnderline` are parameters of
`appendRowTo`, `synchronizedOutput` gates the frame brackets — and the widget
tree never sees any of them. `NonInteractiveTerminal` implements all thirteen as
`false`/`NONE` ([`terminal.kt`][terminalkt]), so "no capabilities" is a first-
class value rather than a degraded path.

The lesson for [friction §2][friction] is placement: a capability record can be
honest and complete without being visible to drawing code at all, because the
ladder it describes (truecolor → 256 → 16 → none; Kitty underline → plain
underline) is a **lowering** applied once, when cells become bytes.

## Q3 — semantic operations or primitives

**Primitive, minimally.** Two operations. No `scrollbar`, no `border`, no
shadow, no text input — those words do not appear in `mosaic-runtime`'s common
sources. `Background` is a `DrawModifier` that calls `drawRect(background = color)` then
`drawContent()` ([`layout/Background.kt`][background]). A border is not library
code at all: the `rrtop` sample defines its own `Modifier.border`, a
`DrawModifier` taking eight box-drawing `Char` parameters, in application space
([`samples/rrtop/…/Border.kt`][rrtopborder]).

This does not contradict [F4](./comparison.md)
so much as expose its precondition. F4's axis — _where the lowering lives_ —
only has force when there is something to lower **to**. Mosaic has one device
class, so "semantics must survive to the backend so it can degrade them" buys
nothing, and the drawing vocabulary shrinks to the two operations a cell grid
natively supports. The semantics are not lost: they live in the retained
`MosaicNode` tree, which is above the painter and is what `dumpNodes()` prints.

That is the shape of the answer to the umbrella's open question. If a toolkit's
targets genuinely disagree, the way to keep semantics is to keep the **node
tree** shared and let each target's painter be small and native — not to widen
one painter until it can express both.

## Q4 — command shape

**No reified command stream** — `drawTo` is virtual dispatch, like Slint and Qt.
And yet Mosaic has every property [F3](./comparison.md)
credits to reification, because **the frame itself is the value**:

```kotlin
fun draw(): TextCanvas {
	val surface = TextSurface(width, height)
	topLayer.drawTo(surface)
	return surface
}
```

— [`layout/Node.kt`][layoutnode]. A `TextSurface` is a plain `TextPixel` array.
It is collected, compared and replayed — the test library's seam is a
`SnapshotStrategy<T>` whose default implementation is literally
`mosaic.draw().render(AnsiLevel.NONE, false)`
([`testing/TestMosaic.kt`][testmosaic]), and the runtime's own
`AnsiRenderingTest` asserts on those strings.

**This complicates F3.** F3 credits reification with recording, replay, culling
and comparison, and that is why the `DrawOp[]` display list earns its keep:
`RecordingCanvas` and the op-stream parity harness both need values. Mosaic
shows the cheaper alternative for a cell target: **compare frames, not
commands.** A cell grid is already a comparable value, and comparing it tests
the composition of operations rather than their sequence — usually the property
a golden test actually wants. Reification is still right for `sparkles:ui`,
because a GPU frame is _not_ cheaply comparable, and the op stream is what lets
one scripted session be compared across both targets — but that is the reason,
stated, rather than an assumption.

Note also that without a command type Mosaic still acquires a
one-shape-for-every-intent encoding one level down: `TextPixel` carries six
fields, most `Unspecified` for a typical cell, and `drawRect` takes seven
defaulted parameters of which a background fill uses one. The uniform-width
half of [friction §4][friction] — a `PopClip` that carries nothing costing what
a `TextRun` costs — is the same pressure seen from storage rather than from the
call: it is what happens when one entry point serves several intents.

## Q5 — sub-unit placement

**Refused outright.** The toolkit has no unit below a cell and offers no
spelling for one. `DrawStyle.Stroke`'s own doc says so:

> `@param width` Configure the width of the stroke in cells
>
> — [`layout/DrawStyle.kt`][drawstyle]

A stroke of width 1 is a full cell on each side; when `strokeWidth * 2` exceeds
the rect it silently becomes a fill ([`layout/DrawScope.kt`][drawscope]). There
is no `RuleEdge` equivalent, no hairline, and no fidelity ladder.

What makes this a finding rather than an absence is that Mosaic **knows about
pixels and deliberately keeps them out**. `Terminal.Size` carries `columns`,
`rows` **and** `width`/`height` in pixels, and the capability record names
`kittyGraphics`, `kittyTextSizingScale` and `kittyTextSizingWidth`
([`terminal/Terminal.kt`][terminalapi]) — every ingredient a Notcurses-style
sub-cell ladder needs. None of it reaches `DrawScope`: the pixel size is state
for the application to read, not vocabulary for the painter.

This supports [F6](./comparison.md)'s
diagnosis — a float seam relocates the sub-unit question rather than dissolving
it — and adds a third option beside continuous coordinates and a named fidelity
over a queried device unit: **name nothing, and let the application spend the
sub-cell budget by choosing code points.** Coherent for one device class; not
for ours, where the raylib and Skia canvases have real device pixels and
`RuleEdge` reads as an apology for them.

## Q6 — resolved appearance, semantic role, or both

**Neither.** There is no semantic role, no theme and no palette in Mosaic at
all; `Color` is an RGB value. What it has instead is a third answer worth
naming: an **`Unspecified` sentinel per attribute, resolved by accumulation into
the cell**.

```kotlin
private inline fun TextPixel.updateTextPixel(codePoint: Int, foreground: Color, /* … */) {
	if (codePoint.isSpecifiedCodePoint) { this.codePoint = codePoint }
	if (foreground.isSpecifiedColor) { this.foreground = foreground }
	// background / textStyle / underlineStyle / underlineColor likewise
}
```

— [`layout/DrawScope.kt`][drawscope]. A `Modifier.background(color)` paints a
rect that specifies only `background`, leaving each cell's code point and
foreground untouched; a later `drawText` overwrites the code point and
foreground and leaves the background. Style composition is therefore performed
by the **surface**, per attribute, by painter's algorithm — no operation carries
a resolved appearance beside a role, and no consumer re-resolves one.

The cost is that "inherit" and "explicitly transparent" become one value and
draw order becomes semantically load-bearing. The benefit is one representation
where [friction §6][friction] has us paying for two: six of our eight payloads
store a `Slot` beside the resolved colours their primitive paints from.
Reconstructing a `Visual` on demand from those fields, rather than storing one,
keeps the hedge cheap — it does not turn it into a decision. Mosaic's answer is
not directly transferable, since the HTML interpreter emitting class names
needs the role, but it shows the hedge is not forced: a partial,
sentinel-bearing appearance is a third point between "resolved" and "semantic".

## Q7 — payload ownership

**Not a problem Mosaic can have, and the one lifetime rule it does have points
the other way.** Text payloads are Kotlin `String`/`AnnotatedString` —
immutable, shared, garbage-collected — so [friction §7][friction] has no
analogue here: `TextRun.text` is a `const(char)[]` copied into a frame arena and
borrowed from it, valid while the buffer that built it is alive and unreset, and
a Kotlin string is subject to no such window. A `TextSurface` is allocated fresh
on every `draw()` ([`layout/Node.kt`][layoutnode]), so no frame data outlives
its frame either.

The inversion worth noting is that the reuse hazard sits on the **output**, and
is documented rather than enforced:

> Note: The returned `CharSequence` is only valid until the next call to this
> function, as implementations are free to reuse buffers across invocations.
>
> — `Rendering.render`, [`rendering.kt`][rendering]

`AnsiRendering` holds one `StringBuilder` for the process lifetime and
`clear()`s it per frame. The pattern is: **share the payloads freely, reuse the
one buffer that is genuinely hot, and document that one** — a milder form of
[F8](./comparison.md)'s "copy,
refcount or arena-allocate; do not borrow across a frame", and the mildest
mechanism of the eight it catalogues.

## Q8 — can a backend ask the scene its extent?

**Yes, and it is the only way a surface ever gets sized.** The extent flows out
of layout: `MosaicNode.draw()` reads the root node's measured `width`/`height`
and allocates a `TextSurface` of exactly that size. The consumer then reads it
back off the frame — `AnsiRendering` stores `lastHeight = surface.height` and
uses it next frame to decide how many stale lines to move up over and clear
([`rendering.kt`][rendering]).

**This confirms [F7](./comparison.md), and
picks a side of its axis.** F7 separates three questions — surface, layout and
ink extent — and puts the real choice between maintained-at-construction and
derived-by-scan. Mosaic keeps the three apart and answers all of them from the
scene, maintained: the terminal's own `columns`/`rows` never size the surface,
being ambient state a composable reads via `LocalTerminalState`. Content
decides, and the encoder adapts to whatever it is handed, frame by frame.

That is exactly `skia-canvas-render.d`'s situation in [friction §8][friction]:
an offscreen consumer with no externally-given size, which derives the extent by
scanning every operation's rect because nothing reports it. Mosaic gets the same
number from **layout**, exactly and for free, and never scans. It is the
existence proof that a layout extent query is the whole answer for the offscreen
case, not a supplement to a self-describing display list.

## Strengths

- **The portable/non-portable boundary is an artifact boundary, and it holds.**
  Depending on `androidx.compose.runtime` without `androidx.compose.ui` is a
  compile-time-enforced statement about which layer is target-neutral.
- **The `Applier` is a four-method contract** with no drawing, layout or
  geometry in it — the cleanest "shared layer above" this survey has seen.
- **A two-operation drawing vocabulary**, the honest minimum for a cell grid:
  nothing in it needs to lie.
- **Device capabilities are one documented record** with a total
  "nothing supported" implementation.
- **The frame is a value**, so golden testing needs no recorder.

## Weaknesses

- **There is no renderer seam.** `drawTo(canvas: TextSurface)` names a concrete
  internal class; a second painter means editing every layer class. Mosaic did
  not choose one seam for two targets — it chose zero seams for one.
- **Text measurement is a code-point count**, so wide and combining characters
  mis-measure. The layering is right and the answer is wrong.
- **No clipping, and out-of-bounds is a `check` failure** — no
  optional-primitive bargain to learn from, and no story for overflow.
- **`Unspecified` conflates "inherit" with "none"** and makes draw order
  semantically significant.
- **A `String` render target was removed rather than maintained** — see
  [`CHANGELOG.md`][changelog], 0.17.0: "`renderMosaic` was removed without
  replacement. As the capabilities of the library grow, supporting a string as a
  render target was increasingly difficult." That is the clearest evidence in
  the tree that _multiple_ targets are exactly the cost this design declined to
  pay.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                     | Trade-off                                                                                               |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Depend on `compose.runtime`, never `compose.ui`                    | The reactive core is target-neutral; the drawing layer is not                                 | Every layout and modifier type must be re-declared, forked file by forked file                          |
| Re-declare `Measurable`/`Placeable`/`Constraints` in cell integers | Compose's measure/place protocol is sound; its `Density`/`Dp` unit vocabulary is meaningless  | Two near-identical protocols exist in the ecosystem; stale doc comments still say "pixels"              |
| `drawTo(canvas: TextSurface)` — a concrete type, not an interface  | One target: an interface would be an abstraction over a set of size one                       | A second painter is a refactor, not an implementation                                                   |
| Two drawing operations only                                        | A cell grid natively supports filling cells and writing runs; anything else would be emulated | Every richer concept (border, table, gauge) is re-implemented per application                           |
| Attribute-level `Unspecified` sentinels composed into the cell     | Style layering falls out of paint order; no op carries a full appearance                      | "Inherit" and "none" are indistinguishable; draw order becomes semantics                                |
| Capabilities on the terminal, consumed only when encoding          | Colour depth and underline style are lowering decisions, not drawing decisions                | Widget code cannot adapt to a capability (e.g. choose a different glyph when Kitty graphics is present) |
| Surface sized from the measured root                               | Content extent is already known once layout runs                                              | The encoder must handle a frame that changes size every frame                                           |

## Bearing on the proposal

1. **The umbrella's open question gets a direct answer: split the seam, share
   the tree.** Mosaic ported a composition runtime across a boundary a drawing
   vocabulary could not cross, and drew that boundary at the artifact split
   between "runtime" and "UI". Read against
   [`comparison.md`'s "What this does not settle"](./comparison.md#what-this-does-not-settle):
   the datum is not that one seam _can_ span cells and pixels, but that a
   project spanning a comparable gap **did not try** and lost nothing above the
   seam by not trying. The thing worth protecting is the widget/layout tree, not
   `isCanvas`.

2. **Confirms F7, on the side [friction §8][friction] needs.** Mosaic's surface
   is sized by the scene, every frame, and its ANSI encoder consumes that extent
   to clear stale lines. The extent is maintained at construction — layout
   already computed it — never derived by scanning. That is the remedy for the
   offscreen case: a layout extent query, which `CmdBuffer` (`length` and a
   run's `measure`) does not offer, so `skia-canvas-render.d` folds `op.rect`
   itself.

3. **Complicates F3.** Reification is not the only route to comparable frames.
   For a cell target the frame buffer is already a value, and Mosaic's entire
   golden-test story rides on that with no recorder. Keep `DrawOp` and its
   closed sum, but state the reason as _"the op stream is what makes one
   scripted session comparable across both targets"_ — not _"otherwise we could
   not test"_, which for `GridCanvas` is false.

4. **Qualifies F4.** Semantic draw operations answer "how does this backend
   degrade a scrollbar". Mosaic keeps its semantics in the retained node tree
   and gives the painter two primitives; nothing is lost, because nothing has to
   degrade. Before acting on [friction §3][friction], decide whether `scrollbar`
   is in the seam because the lowering must live there, or because the seam is
   the only shared vocabulary we have. If the latter, a shared _widget_
   vocabulary above small native painters removes the pressure entirely.

5. **Confirms F1 from a fourth direction, and separates two questions.**
   Measurement is off the painter even in a toolkit with exactly one painter and
   no shaping. But Mosaic's answer is a code-point count, which is wrong for CJK
   and combining marks — so moving `measure` off `isCanvas` fixes the layering
   and says nothing about correctness. `cellsOf` is the better _answer_ sitting
   in the worse _place_; keep the answer when relocating it.

6. **Adopt the capability record's placement, not just its shape.**
   `Terminal.Capabilities` is F5's stated floor done well — thirteen documented
   fields with a total no-capability implementation — and it is read at the
   byte-encoding step, never by drawing code. That is a cleaner cut than
   `__traits(compiles, …)` probing for `pushClip`, `rule`, `scrollbar` and
   `popClip` at each interpreter call site ([friction §2][friction]): a
   capability governs a **lowering**, so it belongs where lowering happens.

7. **A third option for [friction §6][friction].** Attribute-level `Unspecified`
   with composition-by-paint-order is neither "resolved" nor "semantic", and it
   carries one appearance channel where our payloads carry resolved colour and a
   `Slot`. It does not serve the HTML interpreter's class names, so it is not a
   drop-in — but it falsifies the framing that the choice is binary.

8. **Reject the seamlessness.** `drawTo(canvas: TextSurface)` is the one thing
   here not to copy: three backends implement `isCanvas` — a cell grid, raylib
   and Skia — and the structural typing that lets a `@system` GPU canvas and a
   `@safe` recorder satisfy one concept with neither lying is what the friction
   log records as working. Keep it.

## Sources

Read from a clone of `JakeWharton/mosaic` at `trunk`,
`ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9`, resolved with
`gh api repos/JakeWharton/mosaic/commits/trunk --jq .sha`; every path below was
verified at that SHA with `git cat-file -e`.

- [`mosaic-runtime/build.gradle`][runtimegradle], [`gradle/libs.versions.toml`][libs]
  — `compose.runtime`, not `compose.ui`.
- [`mosaic.kt`][mosaic] — `MosaicNodeApplier`, `MosaicComposition`, the frame
  listener and the snapshot apply observer.
- [`layout/Node.kt`][layoutnode] — `MosaicNode`, `MosaicNodeLayer`, the modifier
  fold, `drawTo`, `draw()`.
- [`surface.kt`][surface] — `TextCanvas`, `TextSurface`, `TextPixel`, and
  `appendRowTo`'s SGR diffing.
- [`layout/DrawScope.kt`][drawscope], [`layout/DrawStyle.kt`][drawstyle],
  [`layout/DrawModifier.kt`][drawmodifier], [`layout/Background.kt`][background]
  — the two drawing operations, stroke width in cells, `drawBehind`.
- [`layout/Measurable.kt`][measurable], [`layout/Placeable.kt`][placeable],
  [`layout/MeasurePolicy.kt`][measurepolicy],
  [`ui/unit/Constraints.kt`][constraints] — the re-declared layout protocol.
- [`text/TextLayout.kt`][textlayout], [`ui/Text.kt`][text] — measurement as a
  code-point count, owned by the composable.
- [`rendering.kt`][rendering] — `Rendering`, `AnsiRendering`, `DebugRendering`;
  [`testing/TestMosaic.kt`][testmosaic] — `SnapshotStrategy`.
- [`terminal/Terminal.kt`][terminalapi], [`terminal.kt`][terminalkt] — the
  capability record and its total no-capability implementation.
- [`README.md`][readme], [`CHANGELOG.md`][changelog] — the design thesis, and
  the removal of the string render target.
- In-repo: [`docs/research/tui-libraries/mosaic.md`](../tui-libraries/mosaic.md)
  reads the same project as a TUI toolkit;
  [`imtui.md`](../tui-libraries/imtui.md) is the opposite cut — a pixel
  draw-list vocabulary preserved and translated downward into cells.

<!-- References -->

[rev]: https://github.com/JakeWharton/mosaic/tree/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9
[runtimegradle]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/build.gradle
[libs]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/gradle/libs.versions.toml
[mosaic]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/mosaic.kt
[layoutnode]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/layout/Node.kt
[surface]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/surface.kt
[drawscope]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/layout/DrawScope.kt
[drawstyle]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/layout/DrawStyle.kt
[drawmodifier]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/layout/DrawModifier.kt
[background]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/layout/Background.kt
[measurable]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/layout/Measurable.kt
[placeable]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/layout/Placeable.kt
[measurepolicy]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/layout/MeasurePolicy.kt
[constraints]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/ui/unit/Constraints.kt
[textlayout]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/text/TextLayout.kt
[text]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/ui/Text.kt
[rendering]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/rendering.kt
[terminalapi]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-terminal/src/commonMain/kotlin/com/jakewharton/mosaic/terminal/Terminal.kt
[terminalkt]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-runtime/src/commonMain/kotlin/com/jakewharton/mosaic/terminal.kt
[testmosaic]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-testing/src/commonMain/kotlin/com/jakewharton/mosaic/testing/TestMosaic.kt
[readme]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/README.md
[changelog]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/CHANGELOG.md
[eventparser]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/mosaic-tty-terminal/src/commonMain/kotlin/com/jakewharton/mosaic/tty/terminal/EventParser.kt
[rrtopborder]: https://github.com/JakeWharton/mosaic/blob/ac3051d12da3a1a90d6fb4bbc9ca1e2dd336c2a9/samples/rrtop/src/commonMain/kotlin/example/common/Border.kt
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
