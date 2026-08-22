# Qt — `QPaintEngine`, the declared feature set

**Category:** virtual paint device. **Last reviewed:** August 23, 2026.
Pinned at [`d0787745`][rev] (qtbase); read alongside the
[Qt 6 `QPaintEngine` reference][qpe].

The prior generation's answer to "one drawing API, many devices", and the only
subject in this survey that answers friction §2 head-on: Qt states what a
backend can do, in data, and lets the caller ask.

| Field                | Value                                                                                                                                                                                                                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**         | C++                                                                                                                                                                                                                                                                                            |
| **License**          | `LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only` ([SPDX header][engineh])                                                                                                                                                                                           |
| **Repository**       | [`qt/qtbase`][repo] (GitHub mirror of `code.qt.io`)                                                                                                                                                                                                                                            |
| **Documentation**    | [`QPaintEngine`][qpe], [Paint System][paintsys]                                                                                                                                                                                                                                                |
| **Category**         | virtual paint device                                                                                                                                                                                                                                                                           |
| **Pinned revision**  | [`d0787745aa43e5baf49de876f917946df6aceca5`][rev]                                                                                                                                                                                                                                              |
| **Target range**     | CPU raster, OpenGL, printers/PDF, SVG, platform 2D APIs — every target can fill a rectangle                                                                                                                                                                                                    |
| **Backends shipped** | `QPaintEngine::Type` names the shipped and historical engines: `Raster`, `X11`, `Windows`, `CoreGraphics`, `OpenGL`, `OpenGL2`, `Direct2D`, `Direct3D`, `OpenVG`, `Blitter`, `Pdf`, `SVG`, `Picture`, `PaintBuffer`, plus `User`/`MaxUser` ids for third parties ([`qpaintengine.h`][engineh]) |
| **The seam**         | `class QPaintEngine` — an abstract base class of `virtual draw*` methods plus a declared `PaintEngineFeatures` bitmask                                                                                                                                                                         |
| **The intermediate** | none for drawing: `QPainter` calls engine virtuals directly, and emulates what an engine cannot do                                                                                                                                                                                             |

## Overview

### What it solves

One painting API (`QPainter`) has to reach a software rasterizer, a GPU, a
printer, a PDF writer and a platform 2D API, across engines whose feature sets
genuinely differ — a printer cannot alpha-blend, a blitter cannot fill a
conical gradient. Qt's answer is an abstract base class for the device plus a
_declaration_, in data, of which optional features that device has, so
`QPainter` can emulate the rest once instead of every engine degrading on its
own.

### Design philosophy

The class documentation states both the role and the extension contract
([`qpaintengine.cpp`][enginecpp]):

> The QPaintEngine class provides an abstract definition of how QPainter draws
> to a given device on a given platform.
>
> […] If one wants to use QPainter to draw to a different backend, one must
> subclass QPaintEngine and reimplement all its virtual functions. The
> QPaintEngine implementation is then made available by subclassing
> QPaintDevice and reimplementing the virtual function
> QPaintDevice::paintEngine().

And the capability model, stated on the enum itself, is the whole of friction
§2's answer in four sentences ([`qpaintengine.cpp`][enginecpp]):

> This enum is used to describe the features or capabilities that the paint
> engine has. If a feature is not supported by the engine, QPainter will do a
> best effort to emulate that feature through other means and pass on an alpha
> blended QImage to the engine with the emulated results. Some features cannot
> be emulated: AlphaBlend and PorterDuff.

## Q1 — measurement is not on the paint engine

`QPaintEngine` draws text via `drawTextItem(const QPointF&, const QTextItem&)`
and has no measurement method. Sizing lives in Qt's separate text
infrastructure ([`QFontMetrics`][fontmetrics] and the font engines beneath it).

**Two independent subjects now agree** — Slint and Qt — that text measurement
does not belong on the painter. Neither is a terminal toolkit, so this is not
an artifact of our unusual constraint; it is the ordinary answer.

## Q2 — the contract is declared and queryable

`QPaintEngine::PaintEngineFeature` is a flag enum — `AlphaBlend`,
`Antialiasing`, `BlendModes`, `BrushStroke`, `LinearGradientFill`,
`RadialGradientFill`, `ConicalGradientFill`, `PainterPaths`,
`PixmapTransform`, `PorterDuff` and more — and an engine advertises its set.
Callers ask `hasFeature(...)`, which is a one-line mask test against the
engine's own `gccaps` ([`qpaintengine.h`][engineh]).

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

> [!IMPORTANT]
> Qt itself later abandoned this model rather than extending it. Read
> [`qt-quick-scenegraph.md`][sg] next: the scene graph queries API identity and
> hardware limits, never "will you draw this", and documents its degradation
> policy as silence. The survey's model subject for declared capabilities
> dropped the model.

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
inheritance buys here that a concept does not. Its documentation
([`qpaintengine.cpp`][enginecpp]):

> This function draws the text item \a textItem at position \a p. The default
> implementation of this function converts the text to a QPainterPath and
> paints the resulting path.

So an engine that implements paths gets text for free. `drawPath`'s default is
the same pattern read from the other end: it does nothing, but warns
`"QPaintEngine::drawPath: Must be implemented when feature PainterPaths is set"`
— the declaration and the implementation check each other. Our `isCanvas` has
no equivalent of a default implemented in terms of other primitives — a canvas
either has a method or the interpreter skips the op.

## Q5 — sub-unit placement

Floats (`QPointF`, `QRectF`); no sub-unit problem, and no declared precision
model either. Like Slint, Qt dissolves friction §5 by having a continuous
coordinate space rather than by naming positions in a discrete one.

## Q6 — resolved or semantic styling

Resolved. The engine receives a state (`QPainterState`) with concrete pen and
brush; there is no semantic role. Qt therefore pays for one representation, not
two — the same result as Slint, reached from the opposite end of the
semantic/primitive axis, which is evidence that carrying `visual` _and_ `slot`
(§6) is a cost we chose rather than one the problem imposes.

## Q7 — payload ownership

`QTextItem` and `QPixmap` are borrowed for the call; `QPixmap` is implicitly
shared, so retaining one is cheap and explicit. The lifetime rule for the
engine itself is stated flatly — "QPaintEngine is created and owned by the
QPaintDevice that created it" ([`qpaintengine.cpp`][enginecpp]) — which is the
same instinct as Slint's backend-owned cache: the party that knows a lifetime
owns the thing.

## Q8 — extent query

The paint _device_ declares its extent (`QPaintDevice::width()`/`height()`,
[`qpaintdevice.h`][device]), not the command stream. The scene does not know
its own size; the surface does. That inverts friction §8 and is arguably the
better shape — a backend allocating a surface knows the size because it chose
it.

## Strengths

- **Capability is data, in one place.** `PaintEngineFeatures` is a single
  bitmask an engine sets once; a reader learns the whole negotiable surface
  from one enum.
- **A stated floor.** `AlphaBlend` and `PorterDuff` are documented as
  un-emulatable, so "optional" and "required" are distinguishable — the exact
  distinction `sparkles:ui`'s optional primitives lack.
- **Degradation lives once, in the framework.** A new engine inherits every
  emulation path for free, and the emulated result arrives in a form
  (`QImage`) any engine can consume.
- **Defaults are expressed in terms of other primitives.** `drawTextItem` →
  `QPainterPath` means implementing paths implements text.
- **Declaration and implementation cross-check.** `drawPath`'s default warns if
  an engine claims `PainterPaths` and does not override it.
- **Third-party engines are anticipated**, down to reserved `Type` ids
  (`User = 50`).

## Weaknesses

- **The required method set is the class, not the declaration.** `hasFeature`
  answers "how well", never "at all"; the subclassing contract is prose
  ("reimplement all its virtual functions").
- **Emulation is invisible and unrefusable.** A caller cannot ask for a real
  gradient or be told no; it silently receives an emulated `QImage` and pays
  the cost.
- **The bitmask only covers what the framework can emulate.** A capability Qt
  has no fallback for cannot be expressed as a feature at all.
- **The enum is closed and versioned into the ABI**; note the two comment-only
  reserved bits at `0x10000000` and `0x40000000` ([`qpaintengine.h`][engineh]),
  used for emulation bookkeeping rather than by engines.
- **Qt's own verdict is negative.** The scene graph replaced this seam without
  carrying the capability model forward.
- **Inheritance ties the seam to a C++ class hierarchy** — the mechanism that
  makes the defaults work is also what a structurally-typed concept cannot copy
  directly.

## Key design decisions and trade-offs

| Decision                                                                        | Rationale                                                                                    | Trade-off                                                                             |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Declare optional capabilities as a **bitmask** (`PaintEngineFeatures`)          | One place to read, one place to set, testable with a mask                                    | Closed and ABI-frozen; cannot express a capability the framework has no emulation for |
| **Emulate in the framework**, not in the backend                                | Written once; a new engine gets every fallback for free                                      | The caller cannot see, cost, or refuse the emulation — it just gets a `QImage`        |
| Name two features as **un-emulatable** (`AlphaBlend`, `PorterDuff`)             | A floor makes the rest genuinely negotiable                                                  | The floor is documented in a doc comment, not enforced by any type                    |
| **Primitive** operations only (rects, paths, pixmaps, text items)               | Every target Qt cares about can fill a shape; no widget vocabulary to keep in sync           | A target with a fidelity floor (a cell grid) cannot recover intent from filled shapes |
| **Abstract base class**, not a structural concept                               | The required method set _is_ the class; defaults can be written in terms of other primitives | Only works with inheritance; a DbI concept must re-create defaults with a mixin       |
| Defaults defined **in terms of other primitives** (`drawTextItem` → `drawPath`) | Keeps the genuinely-required set small without losing capability                             | Silent quality cliff: outline-painted text is not hinted, rasterized text             |
| Extent belongs to the **`QPaintDevice`**, not the scene                         | The party allocating the surface already knows its size                                      | No answer for "size this surface to its content"; the scene is never asked            |
| Payloads **borrowed**, with implicit sharing (`QPixmap`)                        | No lifetime obligation in the common case; retention is cheap when wanted                    | Implicit sharing hides copies; a deferred engine must retain deliberately             |

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
5. **Weigh this subject against Qt's own later answer.** The capability bitmask
   is the strongest §2 precedent in the survey and was abandoned by the vendor
   that wrote it; adopt the _shape_ on evidence from elsewhere, not on Qt's
   authority ([`qt-quick-scenegraph.md`][sg]).

## Sources

Every `qtbase` path verified to resolve at
[`d0787745aa43e5baf49de876f917946df6aceca5`][rev] over
`raw.githubusercontent.com`. That is the same qtbase revision
[`qt-quick-scenegraph.md`][sg] pins, so the two Qt subjects are read against
one tree.

- The seam: [`src/gui/painting/qpaintengine.h`][engineh] — `class QPaintEngine`,
  `enum PaintEngineFeature`, `enum Type`, `hasFeature`, the `virtual draw*` set
- The contract, in prose: [`src/gui/painting/qpaintengine.cpp`][enginecpp] —
  the `\class` and `\enum PaintEngineFeature` documentation, and the default
  bodies of `drawTextItem` and `drawPath`
- Emulation: [`src/gui/painting/qpainter.cpp`][painter]
- Extent: [`src/gui/painting/qpaintdevice.h`][device]
- Measurement: [`src/gui/text/qfontmetrics.h`][fontmetrics]
- Rendered reference: [`QPaintEngine`][qpe], [Paint System][paintsys]

> [!NOTE]
> The first pass on this subject was read against the rendered Qt 6 reference
> only. The claims above have since been re-grounded in `qtbase` at the pinned
> revision; where the rendered documentation and the source differ, the source
> is what is cited here.

<!-- References -->

[device]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/painting/qpaintdevice.h
[enginecpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/painting/qpaintengine.cpp
[engineh]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/painting/qpaintengine.h
[fontmetrics]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/text/qfontmetrics.h
[painter]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/painting/qpainter.cpp
[paintsys]: https://doc.qt.io/qt-6/paintsystem.html
[qpe]: https://doc.qt.io/qt-6/qpaintengine.html
[repo]: https://github.com/qt/qtbase
[rev]: https://github.com/qt/qtbase/tree/d0787745aa43e5baf49de876f917946df6aceca5
[sg]: ./qt-quick-scenegraph.md
