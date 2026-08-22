# Qt — `QPaintEngine`, the declared feature set

**Category:** virtual paint device. **Last reviewed:** August 22, 2026.
Read against the [Qt 6 `QPaintEngine` reference][qpe].

The prior generation's answer to "one drawing API, many devices", and the only
subject in this survey that answers friction §2 head-on: Qt states what a
backend can do, in data, and lets the caller ask.

## Q2 — the contract is declared and queryable

`QPaintEngine::PaintEngineFeature` is a flag enum — `AlphaBlend`,
`Antialiasing`, `BlendModes`, `BrushStroke`, `LinearGradientFill`,
`RadialGradientFill`, `ConicalGradientFill`, `PainterPaths`,
`PixmapTransform`, `PorterDuff` and more — and an engine advertises its set.
Callers ask `hasFeature(...)`.

This is precisely the shape `sparkles:ui` lacks. Our `isCanvas` checks five
methods while `OpKind` has eight kinds, and the remaining three are discovered
by `__traits(compiles)` at each interpreter call site. A backend author cannot
learn the contract from the concept, and `static assert(isCanvas!T)` passing
says less than it appears to.

**The more interesting half is what Qt does with the answer.** When a feature
is absent, `QPainter` does not simply degrade at the call site — it _emulates_
the feature and hands the engine an alpha-blended `QImage` of the emulated
result. The fallback lives once, in the framework, rather than once per
backend.

Two features are exempt: `AlphaBlend` and `PorterDuff` cannot be emulated. So
Qt's model is not "every capability is optional" but "these are optional and
the framework covers them; these are floor requirements". That distinction is
the missing piece in our own optional-primitive story, where `rule`,
`scrollbar` and the clip pair are all "optional" with no statement of which are
genuinely negotiable.

Worth noting against friction §2 honestly: a flag enum only describes
capabilities the framework already knows how to emulate or route around. It
does not solve "which methods must exist", which is what `isCanvas` gets wrong.
Qt sidesteps that by using an abstract base class — the method set is the class,
and only _quality_ is negotiable.

## Q1 — measurement is not on the paint engine

`QPaintEngine` draws text via `drawTextItem(const QPointF&, const QTextItem&)`
and has no measurement method. Sizing lives in Qt's separate text
infrastructure (`QFontMetrics` and the font engines beneath it).

**Two independent subjects now agree** — Slint and Qt — that text measurement
does not belong on the painter. Neither is a terminal toolkit, so this is not
an artifact of our unusual constraint; it is the ordinary answer.

## Q3 — primitives, not semantics

`drawRects`, `drawLines`, `drawPoints`, `drawEllipse`, `drawPolygon`,
`drawPath`, `drawPixmap`, `drawImage`, `drawTiledPixmap`, `drawTextItem`.

Geometry and images, with no widget vocabulary. Qt therefore sits opposite
Slint on Q3, and the pair brackets the design space: Slint tells the backend
_what a thing is_ so it can degrade knowingly; Qt tells it _what shape to fill_
and emulates anything the backend cannot manage.

Both work. What distinguishes them is where the degradation logic lives — in
the backend (Slint) or in the framework (Qt) — which is a more useful axis than
"semantic vs primitive" and is the one the synthesis should re-cut on.

## Q4 — no reified command

Virtual dispatch on an abstract class, like Slint. Again no tagged union,
because again there is no requirement to record and replay a command stream.

`drawTextItem`'s default implementation is a good illustration of what
inheritance buys here that a concept does not: it _converts the text to a
`QPainterPath` and paints the resulting path_, so an engine that implements
paths gets text for free. Our `isCanvas` has no equivalent of a default
implemented in terms of other primitives — a canvas either has a method or the
interpreter skips the op.

## Q5, Q6, Q7, Q8

- **Q5:** floats (`QPointF`, `QRectF`); no sub-unit problem, and no declared
  precision model either.
- **Q6:** resolved. The engine receives a state (`QPainterState`) with concrete
  pen and brush; there is no semantic role.
- **Q7:** `QTextItem` and `QPixmap` are borrowed for the call; `QPixmap` is
  implicitly shared, so retaining one is cheap and explicit.
- **Q8:** the paint _device_ declares its extent (`QPaintDevice::width/height`),
  not the command stream. The scene does not know its own size; the surface
  does. That inverts friction §8 and is arguably the better shape — a backend
  allocating a surface knows the size because it chose it.

## Bearing on the proposal

1. **A declared capability set is the right shape for §2**, and Qt shows it
   pays for itself only if the framework can _act_ on the answer. A flag nobody
   consults is worse than no flag.
2. **Separate "optional, framework-emulated" from "floor requirement".** Our
   optional primitives are currently one undifferentiated bucket.
3. **Defaults expressed in terms of other primitives** (`drawTextItem` →
   `drawPath`) are how Qt keeps the required set small without losing
   capability. A DbI concept can do this with a `static if` in a mixin; we do
   not.
4. **Extent belongs to the surface, not the scene** — reconsider §8's framing.

[qpe]: https://doc.qt.io/qt-6/qpaintengine.html
