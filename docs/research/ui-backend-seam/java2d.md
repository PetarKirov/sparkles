# Java2D — the seam is a state vector, and the fallback is a superclass call

**Category:** framework-side emulation. **Last reviewed:** August 23, 2026.
Pinned at [`d3e5304c`][rev].

The other way to build [Qt's answer][qt]. Qt declares a
`PaintEngineFeature` bitmask and lets `QPainter` emulate what is missing;
Java2D declares nothing, resolves every draw against a **three-key registry of
rendering loops**, and when the lookup misses it silently manufactures a
software loop. A device advertises acceleration by _overriding a method and
delegating the rest to `super`_, which makes the software floor structurally
unforgettable — and completely invisible to the caller.

| Field                | Value                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------ |
| **Language**         | Java (public + framework layers), C/Objective-C (native loops)                                                     |
| **License**          | GPLv2 with Classpath exception                                                                                     |
| **Repository**       | [`openjdk/jdk`][rev], module `java.desktop`                                                                        |
| **Documentation**    | [`java.awt.Graphics2D`][graphics2d] class javadoc                                                                  |
| **Category**         | framework-side emulation                                                                                           |
| **Pinned revision**  | `d3e5304c0f70aa03a52f5449cb38645a184b23dc`                                                                         |
| **Public seam**      | [`java.awt.Graphics2D`][graphics2d] — abstract class; every drawing verb is primitive (shapes, glyph runs, images) |
| **Backend seam**     | [`sun.java2d.SurfaceData`][surfacedata] + the [`sun.java2d.pipe`][looppipe] role interfaces                        |
| **Backends shipped** | software (`BufImgSurfaceData`, with the `marlin` rasterizer), X11, XRender (`xr`), OpenGL, Direct3D (`d3d`), Metal |
| **Target range**     | 72 dpi screens, HiDPI, printers, metafiles, offscreen `BufferedImage`                                              |

## Overview

### What it solves

One public drawing API — shapes, text, images, in floating-point _user space_ —
must land on a raster whose pixel format, compositing capability and text
rasterizer are all unknown at the call site, and must produce _the same picture_
whether the destination is a GPU-backed window, an in-heap `int[]` of ARGB
pixels, or a printer. [`Graphics2D`][graphics2d] states the coordinate contract
directly:

> All coordinates passed to a `Graphics2D` object are specified in a
> device-independent coordinate system called User Space, which is used by
> applications. The `Graphics2D` object contains an `AffineTransform` object as
> part of its rendering state that defines how to convert coordinates from user
> space to device-dependent coordinates in Device Space.
>
> — [`java/awt/Graphics2D.java`][graphics2d]

### Design philosophy

The javadoc for the same class describes rendering as four abstract phases and
then hands the implementation a broad licence to collapse them:

> The renderer can optimize many of these steps, either by caching the results
> for future calls, by collapsing multiple virtual steps into a single
> operation, or by recognizing various attributes as common simple cases that
> can be eliminated by modifying other parts of the operation.
>
> — [`java/awt/Graphics2D.java`][graphics2d]

That licence is the whole architecture. Java2D never executes the four phases
literally; it **classifies the current rendering state into a small vector of
ordinals, compiles that vector into a set of pipe objects, and caches the
result**. Nothing about the classification is visible above the seam, and
nothing about the fallback is visible below it.

The second philosophical commitment is that the caller may _request_ but never
_require_. [`RenderingHints`][hints] is explicit:

> Note that since these keys and values are _hints_, there is no requirement
> that a given implementation supports all possible choices indicated below or
> that it can respond to requests to modify its choice of algorithm. … The full
> set of supported keys and hints may also vary by destination since runtimes
> may use different underlying modules to render to the screen, or to
> `BufferedImage` objects, or while printing. … Implementations are free to
> ignore the hints completely, but should try to use an implementation
> algorithm that is as close as possible to the request.
>
> — [`java/awt/RenderingHints.java`][hints]

## How it works

### The state vector

[`SunGraphics2D`][sungraphics2d] is the single concrete `Graphics2D` for every
destination. It does not hold a backend; it holds five ordinals plus five
mutable pipe references:

```java
public SurfaceData surfaceData;

public PixelDrawPipe drawpipe;
public PixelFillPipe fillpipe;
public DrawImagePipe imagepipe;
public ShapeDrawPipe shapepipe;
public TextPipe textpipe;
public MaskFill alphafill;

public RenderLoops loops;

public int paintState;
public int compositeState;
public int strokeState;
public int transformState;
public int clipState;
```

Each ordinal is a **complexity ladder**, not an enumeration of kinds:
`PAINT_OPAQUECOLOR = 0` through `PAINT_CUSTOM = 6`; `TRANSFORM_ISIDENT = 0`
through `TRANSFORM_GENERIC = 4`; `CLIP_DEVICE = 0`, `CLIP_RECTANGULAR = 1`,
`CLIP_SHAPE = 2` ([`SunGraphics2D.java`][sungraphics2d]). Ordering matters:
every capability test in the tree is written as `<=`, so a device that handles
"anything up to an alpha colour" writes one comparison rather than a set
membership test.

### Pipe validation

When any attribute changes, `SunGraphics2D` installs
[`ValidatePipe`][validatepipe] — a trampoline that revalidates on the next draw
and then re-dispatches:

```java
public void drawLine(SunGraphics2D sg,
                     int x1, int y1, int x2, int y2) {
    if (validate(sg)) {
        sg.drawpipe.drawLine(sg, x1, y1, x2, y2);
    }
}
```

Validation itself is [`SurfaceData.validatePipe(SunGraphics2D)`][surfacedata] —
a 175-line decision tree over the state vector that assigns `drawpipe`,
`fillpipe`, `shapepipe`, `textpipe`, `imagepipe` and `alphafill` from a fixed
set of pipe singletons built once in a static initialiser (37 `static final`
fields). There is a matching
null-object, [`NullPipe`][nullpipe], "useful for installing as the pipeline when
the clip is determined to be empty or when the composite operation is determined
to have no effect".

**The seam is therefore per-state-change, not per-command.** A draw call carries
geometry only; appearance was resolved into the choice of pipe.

### Loop lookup: a three-key registry with supertype fallback

Below the pipes are **rendering loops** — [`GraphicsPrimitive`][gprim]
subclasses named by operation ([`Blit`][blit], `FillRect`, `DrawLine`,
`DrawGlyphListAA`, `MaskFill`, …), each registered against a triple: a source
[`SurfaceType`][surfacetype], a [`CompositeType`][compositetype], and a
destination `SurfaceType`. The triple is packed into one 32-bit key, eight bits
per component:

```java
public static final synchronized int makeUniqueID(int primTypeID,
                                                  SurfaceType src,
                                                  CompositeType cmp,
                                                  SurfaceType dst)
{
    return (primTypeID << 24) |
        (dst.getUniqueID() << 16) |
        (cmp.getUniqueID() << 8)  |
        (src.getUniqueID());
}
```

Both key types are **chains**, not flat enums. `SurfaceType` documents the
contract:

> Note that you cannot construct a brand new root for a chain since the
> constructor is private. Every chain of types must at some point derive from
> the `Any` node provided here using the `deriveSubType()` method. The presence
> of this common `Any` node on every chain ensures that all chains end with the
> `DESC_ANY` descriptor so that a suitable General `GraphicsPrimitive` object
> can be obtained for the indicated surface if all of the more specific
> searches fail.
>
> — [`sun/java2d/loops/SurfaceType.java`][surfacetype]

`GraphicsPrimitiveMgr.locatePrim` is the triple loop over those chains — a
lexicographic walk from most specific to most general:

```java
for (dst = dsttype; dst != null; dst = dst.getSuperType()) {
    for (src = srctype; src != null; src = src.getSuperType()) {
        for (cmp = comptype; cmp != null; cmp = cmp.getSuperType()) {
            spec.uniqueID =
                GraphicsPrimitive.makeUniqueID(primTypeID, src, cmp, dst);
            prim = locate(spec);
            if (prim != null) {
                return prim;
            }
        }
    }
}
return null;
```

If even that misses, `locate` asks for the registered _general_ loop and lets it
build one on the spot ([`GraphicsPrimitiveMgr.java`][gprimmgr]):

```java
if (prim == null) {
    prim = GeneralPrimitives.locate(primTypeID);
    if (prim != null) {
        prim = prim.makePrimitive(srctype, comptype, dsttype);
    }
}
```

For `Blit` the last resort is `AnyBlit`, which pulls a `Raster` out of both
surfaces and runs `CompositeContext.compose` span by span in Java
([`Blit.java`][blit]) — correct for every combination, and the slowest path in
the system. Nothing above it is told.

### The pipe interfaces

The contract a pipe implements is **split into role interfaces**, each a handful
of methods, in [`sun.java2d.pipe`][looppipe]:

| Interface                        | Methods | Vocabulary                                                                                                            |
| -------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------- |
| [`PixelDrawPipe`][pixeldrawpipe] | 7       | `drawLine`, `drawRect`, `drawRoundRect`, `drawOval`, `drawArc`, `drawPolyline`, `drawPolygon` — integer device coords |
| `PixelFillPipe`                  | 5       | the `fill*` mirror                                                                                                    |
| [`ShapeDrawPipe`][shapedrawpipe] | 2       | `draw(Shape)` / `fill(Shape)`                                                                                         |
| [`ParallelogramPipe`][pgrampipe] | 2       | `fillParallelogram` / `drawParallelogram`, eight `double` coords                                                      |
| [`TextPipe`][textpipe]           | 3       | `drawString`, `drawGlyphVector`, `drawChars`                                                                          |
| `DrawImagePipe`                  | 6       | `copyImage`, `scaleImage`, `transformImage`, …                                                                        |
| [`CompositePipe`][comppipe]      | 5       | the AA tile protocol: `startSequence`, `needTile`, `renderPathTile`, `skipTile`, `endSequence`                        |
| [`LoopBasedPipe`][loopbasedpipe] | 0       | a marker — "Pipes that need `RenderLoops`"                                                                            |

[`LoopPipe`][looppipe] implements five of them at once and forwards straight to
the located loop. Everything else in the tree is an **adapter between two of
these interfaces**: `PixelToShapeConverter` turns integer pixel calls into
`Shape` calls, and [`PixelToParallelogramConverter`][p2pgram] recognises the
cases that a `ParallelogramPipe` can take directly.

## Q1 — measurement units, and who answers

Java2D is the third distinct answer in this survey, and the most interesting
one: measurement is **off the graphics context, but parameterised by it**.

`Graphics2D` has no `measure`. It has `getFontMetrics()` and
`getFontRenderContext()`. [`FontRenderContext`][frc] is an immutable value
object holding exactly three things — an `AffineTransform`, a text-antialiasing
hint value, and a fractional-metrics hint value — and its javadoc states the
dependence outright:

> The `FontRenderContext` class is a container for the information needed to
> correctly measure text. The measurement of text can vary because of rules
> that map outlines to pixels, and rendering hints provided by an application.
> … A character that is rendered at 12pt on a 600dpi device might have a
> different size than the same character rendered at 12pt on a 72dpi device
> because of such factors as rounding to pixel boundaries and hints that the
> font designer may have specified. … A `FontRenderContext` which is directly
> constructed will most likely not represent any actual graphics device, and
> may lead to unexpected or incorrect results.
>
> — [`java/awt/font/FontRenderContext.java`][frc]

So the unit is device pixels, the _answer_ depends on the device, and the
dependence is **reified as a value you can pass around** rather than being
implicit in a live painter. [`FontDesignMetrics`][fdm] memoizes on exactly that
pair — `MetricsKey(Font font, FontRenderContext frc)` with
`hash = font.hashCode() + frc.hashCode()`. A backend does not answer
measurement; it contributes an FRC, and the shared font layer answers.

Two further details bear on [friction §1][friction]:

- **The legacy rung is integer.** [`FontMetrics.stringWidth`][fontmetrics]
  returns `int`; the float-precision answer is a separate method,
  `getStringBounds(String, Graphics)`, returning `Rectangle2D` and taking the
  `Graphics` purely to extract its FRC via the private `myFRC(context)` helper.
  Java2D kept a coarse-unit measurement API alive beside a fine-grained one for
  thirty years, and the coarse one is the one everybody calls.
- **Per-character measurement is documented as wrong.** The class javadoc:
  "Note that the advance of a `String` is not necessarily the sum of the
  advances of its characters measured in isolation because the width of a
  character can vary depending on its context." That is a direct statement that
  `sparkles:ui`'s [`cellsOf(text)`][canvas] — a per-grapheme width sum — is not a
  measurement primitive that generalises.

## Q2 — is the contract stated, or discovered?

**Stated, but in three separate registers, none of which is a capability query.**

1. **Role interfaces.** A pipe declares what it can be asked by which of the
   eight `sun.java2d.pipe` interfaces it implements. This is Java's version of
   `sparkles:ui`'s optional-primitive probing, made explicit at the type level:
   `LoopPipe implements PixelDrawPipe, PixelFillPipe, ParallelogramPipe,
ShapeDrawPipe, LoopBasedPipe`, and the marker interface `LoopBasedPipe`
   carries no methods at all — `SurfaceData.validatePipe` ends with
   `if (sg2d.textpipe instanceof LoopBasedPipe || …) sg2d.loops = getRenderLoops(sg2d);`.

2. **Registration.** A device advertises an accelerated operation by registering
   a `GraphicsPrimitive` under a `(src, comp, dst)` triple. There is no list of
   what a device supports; there is a sorted array of what it registered, and
   `Arrays.binarySearch` over it.

3. **Override-and-delegate.** The real capability declaration is a method
   override. [`MTLSurfaceData`][mtl] overrides `validatePipe` and, for every
   state it cannot accelerate, calls `super.validatePipe(sg2d)`:

   ```java
   } else {
       // do this to initialize textpipe correctly; we will attempt
       // to override the non-text pipes below
       super.validatePipe(sg2d);
       textpipe = sg2d.textpipe;
       validated = true;
   }
   ```

   And the same file states the fallback contract for masked fills in a comment:

   > In all other cases, we return null, in which case the validation code will
   > choose a more general software-based loop.
   >
   > — [`sun/java2d/metal/MTLSurfaceData.java`][mtl]

**This is a genuinely different answer from Qt's**, and it is the one that
matters for friction §2. Qt states the contract as data (`PaintEngineFeature`)
and the framework consults it. Java2D states it as _inheritance_: the software
answer is the base-class implementation, and a backend is a partial override.
The floor cannot be forgotten because forgetting it means not overriding, and
not overriding means you get it.

The price is that **nobody can enumerate what a device accelerates**, including
the device. `SunGraphics2D.getRenderingHint(Key)` returns the value that was
_set_, never what the destination honoured; the accessor is a switch over the
stored ordinals ([`SunGraphics2D.java`][sungraphics2d]). There is no
`hasFeature`, no `NODEGRADE`, no way for a golden test to demand the fast path
and fail otherwise.

## Q3 — semantic operations, or primitives?

**Pure primitives, and the layer above is a different library entirely.**
`Graphics2D` knows shapes, glyph runs and images. It has no notion of a border,
a shadow, a focus ring or a scrollbar; Swing paints those, in Java, out of
`fillRect`/`draw(Shape)` calls, above the seam.

Two consequences worth recording against friction §3.

**First, it is possible.** A toolkit of Swing's breadth was built on a handful of
primitive verbs, so "the backend needs to know a scrollbar was intended" is not
a law. It is a claim that only holds when a backend's _fidelity floor_ is so low
that primitives lose the intent — which is exactly the terminal case, and not a
case Java2D has.

**Second, Java2D pays for the primitivism precisely where fidelity is scarce.**
The one place semantics survive into the seam is text, and there the seam is
three-rung rather than one: a caller may hand down a `String` (the `Font`
performs "whatever basic layout and shaping algorithms the font implements"), an
`AttributedCharacterIterator` (converted to a `TextLayout` that does bidi across
fonts), or a `GlyphVector` that "already contains the appropriate font-specific
glyph codes with explicit coordinates for the position of each glyph"
([`Graphics2D.java`][graphics2d]). Where a target might disagree with the
framework about the answer, the seam carries **a ladder of pre-resolution and
lets the caller choose the rung** — rather than a single semantic op or a single
primitive one.

## Q4 — command shape

**Not answered here, and the reason is instructive.** Java2D never reifies a
drawing command. Dispatch is a virtual call on `sg2d.drawpipe`; the "command" is
the frame on the Java stack. There is consequently no tagged union to get wrong,
no `DrawOp`, and — importantly — no way to record, replay, cull or diff a scene.
`GraphicsPrimitive.traceWrap()` exists (a debug wrapper installed when
`traceflags != 0`, [`GraphicsPrimitive.java`][gprim]) precisely because there is
nothing to inspect otherwise.

What Java2D reifies instead is the **state**, not the commands: the five
ordinals plus the six pipe fields _are_ the value that would otherwise be
attached to each op. That is the single most transferable idea in this subject
for friction §4 and §6 — see Q6.

## Q5 — sub-unit placement

Java2D's coordinates are continuous `double`s in user space, so it does not have
`sparkles:ui`'s problem directly. What it does have is the _inverse_ problem —
a continuous request landing on a discrete grid — and its answer is the shape
friction §5 is looking for: **a named tolerance and a named minimum, never a
named position.**

- **A minimum, for dropout.**
  [`PixelToParallelogramConverter`][p2pgram] takes a `minPenSize` constructor
  parameter documented as "minimum pen size for dropout control" and clamps:
  `lw = Math.max(lw, minPenSize);`. `SurfaceData`'s static initialiser
  constructs the non-AA converter with `1.0` and the AA converters with
  `1.0/8.0` ([`SurfaceData.java`][surfacedata]) — the same hairline intent,
  spelled at two different fidelities, chosen by the framework rather than
  enumerated by the caller.
- **A bounded licence to snap.** `KEY_STROKE_CONTROL` has three values —
  `VALUE_STROKE_PURE` ("geometry should be left unmodified and rendered with
  sub-pixel accuracy"), `VALUE_STROKE_NORMALIZE` ("normalized to improve
  uniformity or spacing of lines"), and `VALUE_STROKE_DEFAULT` — and the key's
  javadoc bounds the damage:

  > If an implementation performs any type of modification or "normalization" of
  > a path, it should never move the coordinates by more than half a pixel in
  > any direction.
  >
  > — [`java/awt/RenderingHints.java`][hints]

  The converter implements exactly that: `normalize(v)` biases toward
  `normPosition` (`0.25` non-AA, `0.499` AA), applied only when
  `sg2d.strokeHint != SunHints.INTVAL_STROKE_PURE`.

So the vocabulary is `(minimum feature size, snap policy, snap tolerance)`. This
supports F5's recommendation to replace `RuleEdge` with a fidelity — and adds
that the fidelity is naturally a **pair**: how thin a thing may get, and how far
it may move to look right.

## Q6 — resolved appearance, semantic role, or both?

**Neither, and this is the finding that most complicates the survey.** A Java2D
draw command carries _no_ appearance at all — not resolved, not semantic. It
carries geometry.

Appearance lives in the graphics state and is resolved in two stages:

1. **Classified into a lookup key.** `SurfaceData.getPaintSurfaceType(sg2d)`
   maps `paintState` to a `SurfaceType` token — `OpaqueColor`, `AnyColor`,
   `OpaqueGradientPaint`, `LinearGradientPaint`, `TexturePaint`, `AnyPaint` —
   and `getFillCompositeType(sg2d)` does the same for the composite. The pair
   plus the destination type is the registry key. This token is _semantic_: it
   names the kind of paint, not its pixels.
2. **Resolved by whoever wins the lookup.** If an accelerated loop is found, it
   resolves the paint on the device (`MTLPaints`). If not, the general path asks
   the application's own `Paint` object for a `PaintContext` and reads rasters
   out of it — [`GeneralCompositePipe.startSequence`][gencomppipe] calls
   `sg.paint.createContext(model, devR, s.getBounds2D(), sg.cloneTransform(), hints)`
   and then composes tile by tile.

The _unresolved_ `Paint` object is thus carried all the way to the bottom, while
a _classification_ of it is carried as a lookup key. `sparkles:ui` carries
`visual` (resolved) and `slot` (semantic) on **every op**, at eighteen fields
apiece. Java2D carries the equivalent pair **once per state change**, memoized
in a 30-entry `RenderCache` keyed by `(src, comp, dst)`
([`SurfaceData.getRenderLoops`][surfacedata]).

Friction §6 records the seam "hedging rather than deciding". Java2D hedges too —
and shows that the hedge is affordable when it is amortised over a state span
rather than replicated per command.

## Q7 — payload ownership

Java (a GC'd language) removes the lifetime question that makes friction §7
sharp, but Java2D still runs into it twice, and the two answers are different:

- **Glyph runs are pooled and explicitly disposed.** [`GlyphList`][glyphlist]
  holds native pointers and "is not marked as finalizable since it is intended
  to be very lightweight"; the documented usage is
  `GlyphList gl = GlyphList.getInstance(); try { … } finally { gl.dispose(); }`.
  `getInstance()` returns one process-wide `reusableGL` when a CAS on an
  `AtomicBoolean` succeeds and allocates otherwise — a single-slot pool with
  allocation as the contention path.
- **The producer is pinned by a strong reference.** This is the direct answer to
  friction §7's "record on one thread, submit on another":

  > A reference to the strike is needed for the case when the `GlyphList` may be
  > added to a queue for batch processing, (e.g. OpenGL) and we need to be
  > completely certain that the strike is still valid when the glyphs images are
  > later referenced. This does mean that if such code discards `GlyphList` and
  > places only the data it contains on the queue, that the strike needs to be
  > part of that data held by a strong reference.
  >
  > — [`sun/font/GlyphList.java`][glyphlist]

- **Images are cached _by the destination_.** `SurfaceData.getSourceSurfaceData`
  consults a per-destination "blit proxy cache" and may substitute a
  device-resident copy of a source image for the original
  ([`SurfaceData.java`][surfacedata]). This is [Slint's][slint] `draw_cached_pixmap`
  bargain reached independently: the party that knows the payload's device
  lifetime owns the cache.

## Q8 — can a backend ask the scene its extent?

**No — and it never needs to, because the surface is the authority.**
[`SurfaceData`][surfacedata] declares `public abstract Rectangle getBounds();`
and `public abstract GraphicsConfiguration getDeviceConfiguration();`. Extent
flows _down_ from the destination, never _up_ from the drawing.

The offscreen case that friction §8 actually cares about — "size a surface to
its content" — is not a Java2D question at all: it is answered above the seam by
`TextLayout`/`Font.getStringBounds` (for text) or `Shape.getBounds2D()` (for
geometry), both of which are pure model queries needing no painter. This is [F7][comparison],
independently confirmed by a fourth subject.

## Strengths

- **The fallback cannot be forgotten.** Making the software implementation the
  superclass, and acceleration a partial override that ends in
  `super.validatePipe(sg2d)`, means every unhandled state is handled by
  construction. A registry-with-a-general-loop has the same property one level
  down: `SurfaceType`'s "every chain ends at `Any`" invariant guarantees a hit.
- **Appearance amortised over a state span.** No per-command appearance field,
  no per-command re-resolution. The cost of classifying paint × composite ×
  destination is paid once per attribute change and cached.
- **Measurement reified as a context value.** `FontRenderContext` makes
  "measurement depends on the device" expressible without coupling the measurer
  to a live painter — measurable offscreen, cacheable, comparable by `equals`.
- **A ladder of pre-resolution for text.** `String` → `AttributedCharacterIterator`
  → `GlyphVector` lets the caller choose how much resolution to keep for itself.
- **Small role interfaces, composed by adapters.** Eight interfaces of 0–7
  methods, and the tree is full of adapters between them
  (`PixelToShapeConverter`, `PixelToParallelogramConverter`,
  `SpanClipRenderer`), so a backend implements the level it is good at.

## Weaknesses

- **Silent degradation with no floor and no refusal.** The gap between "accelerated
  Metal fill" and "read the destination back into a `Raster` and compose in Java"
  is four orders of magnitude and is crossed without a log line, an exception or
  an observable flag. `AnyBlit` and `GeneralCompositePipe` are both reachable
  from ordinary application code.
- **Degradation _policy_ is encoded as graph topology.** Preferring a `SrcNoEa`
  loop over a `SrcOver` loop is expressed by manufacturing a synthetic
  `CompositeType` whose supertype chain happens to enumerate the desired order:

  > The fix is to use the following chain which looks for loops in the following
  > order: `SrcNoEa`, `Src`, `SrcOverNoEa`, `SrcOver`, `AnyAlpha`
  >
  > — [`sun/java2d/loops/CompositeType.java`][compositetype]

  Nothing prints that order; you derive it by walking `getSuperType()`.

- **The contract is unreadable from one place.** `validatePipe` is a 175-line
  nested conditional; `MTLSurfaceData.validatePipe` is another ~100 lines that
  partially shadows it. The union of the two is the real behaviour and exists
  nowhere as a document. This is friction §2's complaint at ten times the scale.
- **Eight bits per key component.** `makeUniqueID` packs `primTypeID`, dst, comp
  and src into 32 bits; `makePrimTypeID` throws `InternalError("primitive id
overflow")` past 255. The registry is not open-ended.
- **No reified command stream**, so no recording, replay, culling, or op-stream
  parity testing — the properties `RecordingCanvas` exists to provide.
- **Hints are unobservable.** `getRenderingHint` echoes the request. An
  application cannot tell whether antialiasing happened.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                         | Trade-off                                                                                  |
| -------------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Resolve capability **per state change**, not per command | Attribute changes are rare relative to draws; classify once, dispatch many        | The seam's behaviour depends on invisible history; a draw call is not self-describing      |
| Fallback = **`super.validatePipe()`**                    | Structurally impossible for a backend to leave a state unhandled                  | The floor is silent; no caller can tell acceleration from emulation                        |
| Loops keyed by `(src, comp, dst)` **chains**             | One registry serves every device, format and blend mode; specificity is automatic | 8-bit key fields; preference order is graph topology, not data                             |
| A **general loop** synthesised on lookup miss            | Correctness for every combination without an N×M×K table                          | The correct-but-slow path (`AnyBlit`, `GeneralCompositePipe`) is silently reachable        |
| Measurement via an immutable **`FontRenderContext`**     | Device dependence made explicit and cacheable without a live painter              | A hand-built FRC "may lead to unexpected or incorrect results" — a footgun by construction |
| Hints are **advisory only**                              | Portability across screen, image and printer destinations                         | No refusable degrade; no golden test can pin the fast path                                 |
| **Many small role interfaces** + adapters                | A backend implements the level it is good at; converters bridge the rest          | The effective contract is the union of eight interfaces plus two decision trees            |
| **Primitive** public API; widgets live in Swing          | One drawing vocabulary, unlimited widget vocabularies above it                    | Only works because every Java2D destination can actually draw a rect                       |

## Bearing on the proposal

1. **Move appearance off the command and onto a state span.** This is the
   sharpest transferable idea here and it **complicates F2 and F6**. The
   [comparison] recommends re-encoding `DrawOp` as a sum type (F2) and deciding
   between `visual` and `slot` (F6); Java2D suggests a third move that makes
   both cheaper — a `setVisual`/`setSlot` state op in the stream, with the
   geometry ops carrying only geometry. `sparkles:ui` already reifies its
   stream, so unlike Java2D it can keep recording and replay while paying
   appearance once per span. Friction §4 and §6, jointly.

2. **Make the software backend the base, not a peer.** `SkiaCanvas`,
   `GridCanvas` and `RecordingCanvas` are three independent implementations of
   one concept, so a new optional primitive silently means "each backend
   forgot it separately". Java2D's `super.validatePipe(sg2d)` shows the
   alternative: a default implementation expressed in terms of the mandatory
   primitives that a backend _delegates to_, rather than a `__traits(compiles)`
   probe that skips the operation entirely. This is [friction §2][friction]'s real fix and
   it is compatible with structural typing (a `mixin template` of defaults, not
   an interface).

3. **Fidelity is a pair, not a scalar.** F5 recommends replacing `RuleEdge`
   with a fidelity. Java2D's is `(minPenSize, normPosition)` plus a
   `STROKE_PURE`/`STROKE_NORMALIZE` policy switch with a documented half-pixel
   bound. `sparkles:ui`'s equivalent would be "this band is at least _f_ of a
   cell thick, and you may move it up to _t_ of a cell to make it look right" —
   which a cell backend reads as "one cell, snapped" and Skia as "one device
   pixel, unsnapped", with no compass anywhere.

4. **Q1: F1 holds, but its unit answer is incomplete.** F1 says measurement does
   not belong on the painter — Java2D agrees, making a fifth unanimous subject.
   But it adds a constraint the other four do not: the answer legitimately
   depends on the destination _and its rendering hints_, and the way to express
   that without coupling is a small immutable **measurement context value**
   passed to the font layer. A `sparkles:ui` `TextMeasure` abstraction should
   take something FRC-shaped (cell metrics, or a scale factor plus a
   hinting/AA policy), not be a bare `Font`.

5. **F3 gains a datapoint in the primitive camp, with a caveat.** Java2D is
   framework-side emulation _with a primitive seam_ — the combination F3's two
   camps do not cover. It shows that "who degrades" and "semantic or primitive"
   are genuinely orthogonal: Java2D degrades in the framework and carries no
   semantics at all, because every one of its destinations can draw a
   rectangle. `sparkles:ui` cannot make that assumption for a terminal, so it
   cannot copy the primitivism wholesale — but it can copy the _scope_: keep
   semantics only where a target's fidelity floor destroys intent, which is
   text and hairlines, not scrollbars whose geometry `scrollbarThumb` already
   computes once.

6. **Adopt a stated floor by making degradation observable, not refusable.**
   F4 recommends a floor plus a refusable degrade. Java2D has neither and is
   demonstrably worse for it — but it also shows that "refusable" is the harder
   half to retrofit into a portable API. The cheap first move is
   _observability_: a canvas reporting which optional primitives it actually
   executed, so `RecordingCanvas` and golden tests can assert on it. Refusal can
   then be layered as a policy over an observable seam.

7. **Do not adopt the state-vector-as-ordinals classification.** It buys Java2D
   a fast `<=` test per capability and costs it a decision tree no one can read.
   `sparkles:ui` has three backends and eight op kinds; the pressure that
   produced `paintState` through `clipState` does not exist here.

## Sources

All paths verified to exist at `d3e5304c0f70aa03a52f5449cb38645a184b23dc` with
`git cat-file -e <sha>:<path>` against a local clone of `openjdk/jdk`; the
revision is that clone's `HEAD` (commit dated July 10, 2026).

- [`java/awt/Graphics2D.java`][graphics2d] — the public seam: coordinate spaces,
  the four-phase rendering process, the three text-argument rungs
- [`java/awt/RenderingHints.java`][hints] — hints are advisory; `KEY_STROKE_CONTROL`
  and its half-pixel normalization bound
- [`java/awt/FontMetrics.java`][fontmetrics] — integer metrics, `myFRC(Graphics)`,
  the "advance is not the sum of advances" note
- [`java/awt/font/FontRenderContext.java`][frc] — measurement parameterised by device
- [`sun/font/FontDesignMetrics.java`][fdm] — `MetricsKey(Font, FontRenderContext)` cache
- [`sun/font/GlyphList.java`][glyphlist] — pooled payload, explicit `dispose()`,
  strong strike reference for queued backends
- [`sun/java2d/SunGraphics2D.java`][sungraphics2d] — the state vector and pipe fields
- [`sun/java2d/SurfaceData.java`][surfacedata] — `validatePipe`, `getMaskFill`,
  `getRenderLoops`, `makeRenderLoops`, `getBounds`, the blit proxy cache
- [`sun/java2d/loops/SurfaceType.java`][surfacetype] — the chain-to-`Any` invariant
- [`sun/java2d/loops/CompositeType.java`][compositetype] — `OpaqueSrcOverNoEa` and
  the topology-encoded preference order
- [`sun/java2d/loops/GraphicsPrimitive.java`][gprim] — `makeUniqueID`, `traceWrap`
- [`sun/java2d/loops/GraphicsPrimitiveMgr.java`][gprimmgr] — `locatePrim`'s triple
  supertype walk and the general-loop fallback
- [`sun/java2d/loops/Blit.java`][blit] — `makePrimitive`, `AnyBlit`
- [`sun/java2d/pipe/PixelToParallelogramConverter.java`][p2pgram] — `minPenSize`,
  `normalize`
- [`sun/java2d/pipe/LoopPipe.java`][looppipe],
  [`ValidatePipe.java`][validatepipe], [`NullPipe.java`][nullpipe],
  [`GeneralCompositePipe.java`][gencomppipe] — the pipe layer
- [`sun/java2d/pipe/PixelDrawPipe.java`][pixeldrawpipe],
  [`ShapeDrawPipe.java`][shapedrawpipe], [`TextPipe.java`][textpipe],
  [`ParallelogramPipe.java`][pgrampipe], [`CompositePipe.java`][comppipe],
  [`LoopBasedPipe.java`][loopbasedpipe] — the role interfaces
- [`sun/java2d/metal/MTLSurfaceData.java`][mtl] — override-and-delegate, and the
  "more general software-based loop" comment

<!-- References -->

[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
[qt]: ./qt-qpaintengine.md
[slint]: ./slint.md
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[rev]: https://github.com/openjdk/jdk/tree/d3e5304c0f70aa03a52f5449cb38645a184b23dc
[graphics2d]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/java/awt/Graphics2D.java
[hints]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/java/awt/RenderingHints.java
[fontmetrics]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/java/awt/FontMetrics.java
[frc]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/java/awt/font/FontRenderContext.java
[fdm]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/font/FontDesignMetrics.java
[glyphlist]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/font/GlyphList.java
[sungraphics2d]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/SunGraphics2D.java
[surfacedata]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/SurfaceData.java
[surfacetype]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/loops/SurfaceType.java
[compositetype]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/loops/CompositeType.java
[gprim]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/loops/GraphicsPrimitive.java
[gprimmgr]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/loops/GraphicsPrimitiveMgr.java
[blit]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/loops/Blit.java
[p2pgram]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/PixelToParallelogramConverter.java
[looppipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/LoopPipe.java
[validatepipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/ValidatePipe.java
[nullpipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/NullPipe.java
[gencomppipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/GeneralCompositePipe.java
[pixeldrawpipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/PixelDrawPipe.java
[shapedrawpipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/ShapeDrawPipe.java
[textpipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/TextPipe.java
[pgrampipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/ParallelogramPipe.java
[comppipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/CompositePipe.java
[loopbasedpipe]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/share/classes/sun/java2d/pipe/LoopBasedPipe.java
[mtl]: https://github.com/openjdk/jdk/blob/d3e5304c0f70aa03a52f5449cb38645a184b23dc/src/java.desktop/macosx/classes/sun/java2d/metal/MTLSurfaceData.java
