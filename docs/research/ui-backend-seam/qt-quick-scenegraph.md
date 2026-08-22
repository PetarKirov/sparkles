# Qt Quick scene graph — the seam Qt built after `QPaintEngine`, and where it split in two

**Category:** retained render tree. **Last reviewed:** August 23, 2026.
Pinned at [`ffc46f28`][qd-rev] (qtdeclarative) and [`d0787745`][qb-rev] (qtbase).

The same vendor as [`qt-qpaintengine.md`](./qt-qpaintengine.md), a generation later,
having concluded that a virtual paint device was the wrong seam for a
GPU-composited toolkit. Read the two together: this is Qt's verdict on Qt's
earlier answer, and the most interesting part of the verdict is that the
replacement did not stay one seam.

| Field           | Value                                                                                              |
| --------------- | -------------------------------------------------------------------------------------------------- |
| Language        | C++                                                                                                |
| License         | `LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only`                        |
| Repository      | [`qt/qtdeclarative`][qd-rev] (scene graph), [`qt/qtbase`][qb-rev] (`QRhi`)                         |
| Documentation   | [Qt Quick Scene Graph][doc-sg], [Scene Graph Adaptations][doc-adapt]                               |
| Category        | retained render tree                                                                               |
| Pinned revision | `ffc46f28ab21b6666dbea46c81cf2726ce682419` / `d0787745aa43e5baf49de876f917946df6aceca5`            |
| Adaptations     | default (RHI: Vulkan, Metal, D3D11, D3D12, OpenGL, Null), `software` (raster `QPainter`), `openvg` |
| Target range    | desktop and mobile GPUs, plus a CPU raster fallback — no sub-pixel-less target                     |

## Overview

### What it solves

Qt Quick needed to draw a scene of animated items on GPUs whose cost model is
draw calls and state changes, not primitives. [`scenegraph.qdoc`][qdoc-sg] states
the motive without hedging:

> Using a scene graph for graphics rather than the traditional imperative
> painting systems (QPainter and similar), means the scene to be rendered can be
> retained between frames and the complete set of primitives to render is known
> before rendering starts. This opens up for a number of optimizations, such as
> batch rendering to minimize state changes and discarding obscured primitives.

The seam is therefore not a painter but a **tree of value-like nodes**, and the
doc is explicit that the painter's defining member is gone:

> The nodes themselves do \b not contain any active drawing code nor virtual \c paint()
> function.

(`\b` and `\c` are qdoc's bold and code markup.) That single sentence is the whole delta against [`QPaintEngine`](./qt-qpaintengine.md).
`QPaintEngine::drawRects` is a call that happens now; `QSGGeometryNode` is a fact
that persists until something calls `markDirty`.

### Design philosophy

Three commitments follow from retention, and each of them shows up as a
constraint on the seam:

1. **The renderer may reorder.** Node order guarantees visual output only —
   "This does not say anything about the actual rendering order in the renderer"
   ([`scenegraph.qdoc`][qdoc-sg]). That licence is what buys batching.
2. **The scene outlives the frame**, so ownership must be declared rather than
   scoped, and the tree can live on a different thread from the model that built it.
3. **Backends differ by capability and the framework will not emulate.** Where
   Qt Widgets' `QPainter` emulated a missing `PaintEngineFeature`, the adaptations
   doc says of `software`: "any attempts to use unsupported features are ignored"
   ([`adaptations.qdoc`][qdoc-adapt]).

## How it works

`QSGNode` is a plain intrusive tree node with a coarse type tag, a flag word, and
a dirty-bit channel ([`qsgnode.h`][qsgnode]):

```cpp
enum NodeType {
    BasicNodeType, GeometryNodeType, TransformNodeType,
    ClipNodeType, OpacityNodeType, RootNodeType, RenderNodeType
};

enum Flag {
    OwnedByParent = 0x0001, UsePreprocess = 0x0002,
    OwnsGeometry  = 0x00010000, OwnsMaterial = 0x00020000,
    OwnsOpaqueMaterial = 0x00040000, IsVisitableNode = 0x01000000
};

enum DirtyStateBit {
    DirtySubtreeBlocked = 0x0080, DirtyMatrix = 0x0100,
    DirtyNodeAdded = 0x0400, DirtyNodeRemoved = 0x0800,
    DirtyGeometry = 0x1000, DirtyMaterial = 0x2000,
    DirtyOpacity = 0x4000, DirtyForceUpdate = 0x8000
};
```

Seven node types is the entire structural vocabulary: geometry, transform, clip,
opacity, root, render, and a bare grouping node. Everything else — a rectangle, a
glyph run, an image, a nine-patch — is a **subclass of `QSGGeometryNode`**
carrying a `QSGGeometry` (an attribute set plus a vertex/index buffer plus a
`DrawingMode`, [`qsggeometry.h`][qsggeometry]) and a `QSGMaterial`
([`qsgmaterial.h`][qsgmaterial]):

```cpp
virtual QSGMaterialType *type() const = 0;
virtual QSGMaterialShader *createShader(QSGRendererInterface::RenderMode) const = 0;
virtual int compare(const QSGMaterial *other) const;
```

That is the "backend gets geometry plus a shader" position in its purest public
form. `compare` exists for one reason, stated in [`qsgmaterial.cpp`][qsgmaterialcpp]:
"The scene graph can reorder geometry nodes to minimize state changes. The compare
function is called during the sorting process". The batcher
([`qsgbatchrenderer_p.h`][batch]) then groups elements into a `Batch` with
`isMaterialCompatible`, a `merged` bit, and shared `vbo`/`ibo`/`ubuf` — the
optimization the retained tree was adopted for.

**But that is only one of Qt's two seams, and it is not the one a backend
implements.** The seam an _adaptation_ implements is `QSGContext`
([`qsgcontext_p.h`][qsgcontext]) — a header stamped "This file is not part of the
Qt API" — and it is an abstract factory of **semantic** nodes:

```cpp
virtual QSGInternalRectangleNode *createInternalRectangleNode() = 0;
virtual QSGInternalImageNode *createInternalImageNode(QSGRenderContext *) = 0;
virtual QSGPainterNode *createPainterNode(QQuickPaintedItem *item) = 0;
virtual QSGGlyphNode *createGlyphNode(QSGRenderContext *, QSGTextNode::RenderType) = 0;
virtual QSGLayer *createLayer(QSGRenderContext *) = 0;
virtual QSGRectangleNode *createRectangleNode() = 0;
virtual QSGImageNode *createImageNode() = 0;
virtual QSGNinePatchNode *createNinePatchNode() = 0;
virtual QSGTextNode::RenderType processTextRenderType(QSGTextNode::RenderType) = 0;
```

So Qt's answer to "one drawing API, many devices" is layered: **public consumers
add geometry and shaders; backends implement widget primitives.** The two tiers
are not interchangeable, and the survey's most useful evidence is what happens
when they meet.

## Q1 — measurement units, and who answers

**Not on the seam, and the payload is not text.** The adaptation-level text node
takes an already-shaped run ([`qsgadaptationlayer_p.h`][adapt]):

```cpp
virtual void setGlyphs(const QPointF &position, const QGlyphRun &glyphs) = 0;
```

and the public one takes an already-laid-out paragraph
([`qsgtextnode.h`][qsgtextnode]):

```cpp
void addTextLayout(QPointF position, QTextLayout *layout,
                   int selectionStart = -1, int selectionCount = -1,
                   int lineStart = 0, int lineCount = -1);
```

Measurement happens above, in QtGui, and the item does it: `QQuickTextPrivate`
holds a `QTextLayout layout` ([`qquicktext_p_p.h`][qqtextpp]) and
[`qquicktext.cpp`][qqtext] sizes with `QFontMetricsF` and
`QTextLine::naturalTextRect()`. The unit is `qreal` device-independent pixels;
the device pixel ratio arrives separately at
`QSGRenderContext::prepareSync(qreal devicePixelRatio, ...)`.

This is now the fifth independent subject to put measurement off the painter, and
Qt's variant is the strongest form of it: **the backend never sees a string at
all.** Compare egui's `Galley` — a retained-tree design and a tessellation design
converge on the same answer from opposite directions, which is what makes
[F1](./comparison.md)
look structural rather than stylistic.

One genuine backend voice on text survives, and it is about fidelity, not size:
`processTextRenderType` lets the adaptation rewrite the requested strategy. The
software backend overrides it to return `QSGTextNode::NativeRendering`
unconditionally ([`qsgsoftwarecontext.cpp`][swcontext]) — the framework proposes,
the backend disposes.

## Q2 — is the contract stated in one place?

Three places, answering three different questions, and none of them is
`QPaintEngine::hasFeature`.

- **What must exist:** `QSGContext`'s pure virtuals. A backend that omits one does
  not compile. This is a _total_ contract in the strongest sense available in
  C++ — but it is private API, so it is not something an outside backend author
  can learn from, or rely on.
- **What API this is:** `QSGRendererInterface` ([`qsgrendererinterface.h`][qsgri])
  exposes `graphicsApi()` returning `Software`, `OpenVG`, `OpenGL`, `Direct3D11`,
  `Vulkan`, `Metal`, `Null`, `Direct3D12`; plus `shaderType()`,
  `shaderCompilationType()` and `shaderSourceType()`. Note the shape: this is
  **identity and shader-language facts**, not drawing capability.
- **What the hardware can do:** one layer down, `QRhi::isFeatureSupported(Feature)`
  and `resourceLimit(ResourceLimit)` ([`qrhi.h`][qrhi]) over 43 features
  (`Tessellation`, `WideLines`, `MultiView`, `Compute`, …) and 14 limits. Again
  hardware facts, not "can you draw a rounded rectangle".

**Qt deleted the capability enum it invented for `QPaintEngine` and did not
replace it.** `PaintEngineFeature` worked because `QPainter` could emulate a
missing feature and hand the engine an image; once the seam became a retained
tree consumed by shader-based batchers, there was nothing generic left to emulate
into. What replaced framework emulation is not backend degradation either — it is
documented silence: unsupported features "are ignored"
([`adaptations.qdoc`][qdoc-adapt]), with `ShaderEffect` and particles named as
things the software adaptation simply does not draw.

For friction §2 this is a two-edged result. The _existence_ half is solved
outright — an abstract base class with pure virtuals states the required surface
in one place, which `isCanvas`'s five-method probe plus three `__traits(compiles)`
call sites does not. The _quality_ half is worse than Qt's own earlier answer.

## Q3 — semantic operations or primitives

**Both, in two tiers — and only the semantic tier is portable.** That is the
finding this subject contributes.

The primitive tier is `QSGGeometryNode` + `QSGMaterial`: vertices plus a shader.
The semantic tier is the adaptation layer, and it is unapologetically
widget-shaped. `QSGInternalRectangleNode` ([`qsgadaptationlayer_p.h`][adapt]) is
seventeen pure-virtual setters for one primitive — `setRect`, `setColor`,
`setPenColor`, `setPenWidth`, `setGradientStops`, `setGradientVertical`,
`setRadius`, four per-corner radii, four corner-radius resets, `setAligned`, and a
**defaulted** `setAntialiasing` whose base implementation is `Q_UNUSED`. Alongside
it sit `QSGGlyphNode`, `QSGInternalImageNode`, `QSGPainterNode`, `QSGSpriteNode`
and `QSGShaderEffectNode`. A public, blessed middle tier — `QSGRectangleNode`,
`QSGImageNode`, `QSGNinePatchNode`, `QSGTextNode` — is obtained from
`QQuickWindow::createRectangleNode()` and friends rather than constructed, so the
adaptation chooses the implementation.

Now the collision. The software adaptation walks the tree and, at a
`QSGGeometryNode`, tries to recover semantics by downcasting
([`qsgsoftwarerenderablenodeupdater.cpp`][swupd], lines 69–85):

```cpp
bool QSGSoftwareRenderableNodeUpdater::visit(QSGGeometryNode *node)
{
    if (QSGSimpleRectNode *rectNode = dynamic_cast<QSGSimpleRectNode *>(node)) {
        return updateRenderableNode(QSGSoftwareRenderableNode::SimpleRect, rectNode);
    } else if (QSGSimpleTextureNode *tn = dynamic_cast<QSGSimpleTextureNode *>(node)) {
        return updateRenderableNode(QSGSoftwareRenderableNode::SimpleTexture, tn);
    } else if (QSGNinePatchNode *nn = dynamic_cast<QSGNinePatchNode *>(node)) {
        return updateRenderableNode(QSGSoftwareRenderableNode::NinePatch, nn);
    } else if (QSGRectangleNode *rn = dynamic_cast<QSGRectangleNode *>(node)) {
        return updateRenderableNode(QSGSoftwareRenderableNode::SimpleRectangle, rn);
    } else if (QSGImageNode *n = dynamic_cast<QSGImageNode *>(node)) {
        return updateRenderableNode(QSGSoftwareRenderableNode::SimpleImage, n);
    } else {
        // We dont know, so skip
        return false;
    }
}
```

> [!IMPORTANT]
> A custom `QSGGeometryNode` with a custom `QSGMaterial` — the public,
> documented way to add content to a Qt Quick scene — is **silently dropped** by
> the software backend. Geometry-plus-shader is portable only across backends
> that have shaders. The vocabulary a heterogeneous backend set can actually
> share is the semantic one, and Qt recovers it by `dynamic_cast` because the
> geometry tier threw it away.

That is a direct, load-bearing complication of
[F3](./comparison.md).
F3 framed semantic-vs-primitive as a free choice whose real axis is where
degradation lives. Qt shows a prior constraint: **primitives below a certain
level are not degradable at all**, so a seam that must span unlike targets has no
choice about carrying semantics. It also complicates
[F2](./comparison.md)'s
implicit sympathy for egui's mesh extreme: egui works because every egui backend
is a triangle rasterizer. `sparkles:ui`'s backend set is not.

## Q4 — the shape of a draw command

**There is no draw command.** There is a heap-allocated polymorphic node with a
seven-value `NodeType` tag, a `Flags` word, and `markDirty(DirtyState)`. Refinement
past those seven values is `dynamic_cast`, as Q3 shows. So Qt is neither a sum
type nor tag-plus-dead-fields; it is the third option, an open class hierarchy —
and it pays the exact cost that shape implies, namely that the discriminant is not
enough to dispatch on and the fallback is a runtime type test that can fail.

What retention buys, and what it costs, is worth stating because
`sparkles:ui` rebuilds its `DrawOp[]` every frame:

- **Buys:** batching (`Batch::isMaterialCompatible`, `merged`, shared buffers) and
  partial update — the software adaptation flushes only changed regions
  ([`adaptations.qdoc`][qdoc-adapt]).
- **Costs:** node lifetime becomes a design problem (three separate ownership
  flags), and the tree needs a thread rendezvous (Q7).

`sparkles:ui` wants neither batching nor partial update from its display list; it
wants recordability and comparability. F2's recommendation — keep the reified
stream, encode it as a sum type — is untouched by Qt, because Qt is not paying for
the same property.

## Q5 — sub-unit placement

Does not arise: `QRectF`, `QPointF` and `qreal` throughout, with the device pixel
ratio supplied out of band at sync time. Qt is the fourth subject in this survey
with continuous coordinates, which keeps reinforcing
[F5](./comparison.md)'s
first half.

The second half — "name a fidelity, not a position" — has a Qt analogue worth
copying, in a different currency. Antialiasing is **not** a backend flag consulted
at draw time; it is extra geometry the framework generates, and a backend opts out
by overriding a predicate: `QSGBasicInternalRectangleNode::supportsAntialiasing()`
returns `true` by default ([`qsgbasicinternalrectanglenode_p.h`][rectnodep]) and
`setAntialiasing` becomes a no-op when it returns `false`
([`qsgbasicinternalrectanglenode.cpp`][rectnode]). A fidelity request that the
backend may decline, decided once before geometry is built rather than at every
call site — which is the shape
[F4](./comparison.md)
asks for, expressed as a virtual predicate rather than a flag enum.

## Q6 — resolved appearance, semantic role, or both

**Both — and neither costs a field.** The semantic role is the node's C++ type;
the resolved appearance is the `QSGMaterial` (or, at the adaptation tier, the
concrete setters). A GPU backend reads `activeMaterial()`; the software backend
reads the role, by `dynamic_cast`. Two consumers with opposite needs are served
without any node carrying a role tag _and_ a resolved-style struct side by side.

That is the cleanest available answer to friction §6, and it composes with F2's
recommendation into a single change rather than two: **in a sum type, the tag is
the slot.** `DrawOp` carries `slot` and `visual` as parallel fields precisely
because `kind` is too coarse to identify what was drawn — the same coarseness that
forces Qt into `dynamic_cast`. A `SumType` whose variants are
`ScrollbarThumb`/`FocusRing`/`Rule` makes the role structural and leaves only
appearance as data.

## Q7 — payload ownership

Declared per node, in flags, and the doc names the choice explicitly
([`scenegraph.qdoc`][qdoc-sg]):

> Ownership of the nodes is either done explicitly by the creator or by the scene
> graph by setting the flag `QSGNode::OwnedByParent`. Assigning ownership to the
> scene graph is often preferable as it simplifies cleanup when the scene graph
> lives outside the GUI thread.

`OwnsGeometry`, `OwnsMaterial` and `OwnsOpaqueMaterial` do the same for a
geometry node's payloads. Ownership is thus a _property of the individual node_,
not of the seam — the same op kind can borrow or own depending on how it was
built.

The threading half is the part friction §7 actually needs. Qt does not solve
"record on one thread, submit on another" with reference counting; it solves it
with a **rendezvous**. Under the threaded render loop, the GUI thread is blocked
while `QQuickItem::updatePaintNode()` runs, and the doc is categorical:

> Synchronization of the QML state into the scene graph. This is done by calling
> the `QQuickItem::updatePaintNode()` function on all items that have changed since
> the previous frame. This is the only time the QML items and the nodes in the
> scene graph interact.

with a matching warning that native graphics and scene-graph interaction must
happen "exclusively on the render thread, primarily during the `updatePaintNode()`
call". This is a **third** answer beyond
[F6](./comparison.md)'s two: not
reference counting, not a backend-owned cache, but a declared window during which
borrowing is legal — after which the borrow is a bug the documentation, rather
than the type system, forbids.

> [!WARNING]
> Qt's rendezvous is enforced by convention. D can do better: `RecordingCanvas`
> plus a `SumType` payload could make the copy-at-sync explicit and checked. The
> transferable idea is the _phase_, not the enforcement mechanism.

## Q8 — can a backend ask the scene its extent?

**Yes, per node, as an opt-in promise** — which is a different answer from every
other subject surveyed so far. `QSGRenderNode` ([`qsgrendernode.h`][rendernode])
declares:

```cpp
virtual RenderingFlags flags() const;   // BoundedRectRendering, DepthAwareRendering,
                                        // OpaqueRendering, NoExternalRendering
virtual QRectF rect() const;
```

and [`qsgrendernode.cpp`][rendernodecpp] documents `rect()` as "the bounding
rectangle in item coordinates for the area render() touches. The value is only in
use when flags() includes BoundedRectRendering, ignored otherwise." The motive is
stated too:

> Reporting the rectangle in combination with BoundedRectRendering is
> particularly important with the `software` backend because otherwise having a
> rendernode in the scene would trigger fullscreen updates, skipping all partial
> update optimizations.

`QSGGlyphNode::boundingRect()` is the same idea at the adaptation tier.

This complicates
[F7](./comparison.md). F7 concluded
that extent belongs to the surface because a backend allocating a surface chose
its size. True — and irrelevant to the case Qt cares about. Qt's surface knows its
size perfectly well; the renderer still needs _per-item_ bounds, for partial
update and occlusion. Friction §8 conflated two questions: "how big is the scene"
(a surface property, F7 is right) and "what does this op touch" (a per-op
property, which `DrawOp` does answer for rects and does **not** answer for
`textRun`, where `rect.width` is an advance in cells and no other subject's
backend would accept that as a bound).

`QSGRenderNode` deserves one more note as the **declared escape hatch**: a node
that renders with the raw graphics API, and pays for the privilege by declaring
`changedStates()`, its `RenderingFlags` promises, and its `rect()`. Its sibling
`QSGPainterNode` / `QQuickPaintedItem` ([`qquickpainteditem.h`][painteditem],
`virtual void paint(QPainter *painter) = 0;`) is the escape hatch _back to the old
seam_ — Qt kept `QPaintEngine` alive as a node kind inside the scene graph rather
than deleting it.

## Strengths

- **The required surface is stated in one place** and enforced by the compiler:
  `QSGContext`'s pure virtuals. No probing, no partial conformance.
- **Role and appearance are carried without duplicating either** — type identity
  is the role, `QSGMaterial` is the appearance.
- **Escape hatches are declared, not implicit.** `QSGRenderNode` buys raw-API
  access by promising bounds, state changes and rendering behaviour.
- **Extent is a per-node opt-in promise**, so the renderer can trust it exactly
  when a node says it may.
- **The seam admits it has tiers.** A convenience layer, a public geometry layer
  and a private adaptation layer are three different audiences, and Qt does not
  pretend one vocabulary serves all three.

## Weaknesses

- **The portable seam is private.** Everything a backend author must implement
  lives behind "This file is not part of the Qt API. … We mean it."
- **Silent skip as the degradation policy.** `// We dont know, so skip` loses
  content with no diagnostic and no way for a caller to demand failure instead —
  the refusable degrade F4 asks for is absent.
- **`NodeType` is too coarse to dispatch on**, so the software backend runs a
  five-deep `dynamic_cast` chain per geometry node, every frame.
- **No capability query about drawing.** `QSGRendererInterface` answers "which
  API", `QRhi` answers "which hardware feature" — nothing answers "will you draw
  this".
- **Retention is not free**: three ownership flags, an eight-bit dirty channel, a
  thread rendezvous enforced by prose, and a node-lifetime rule per subtree.

## Key design decisions and trade-offs

| Decision                                                                 | Rationale                                                                      | Trade-off                                                                                       |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| Retained node tree instead of a `paint()` call                           | Whole scene known before rendering ⇒ batching, reordering, occlusion culling   | Node lifetime, dirty tracking and cross-thread sync become the toolkit's problem                |
| Public seam is geometry + material                                       | Maximum expressive power for custom content on a GPU                           | Non-portable — the software adaptation silently drops what it cannot downcast to a known type   |
| Private seam is a factory of semantic node kinds                         | Only widget-level semantics can be re-implemented by an unlike backend         | Backend authorship is closed; the contract cannot be relied on from outside Qt                  |
| Capability query is API identity (`graphicsApi()`), not drawing features | Post-`QPaintEngine`: nothing generic left for the framework to emulate         | Callers branch on backend identity instead of on capability; unsupported features go unremarked |
| Role carried by C++ type, appearance by `QSGMaterial`                    | Serves resolving and re-resolving consumers with no duplicated field           | Recovering the role costs a `dynamic_cast` chain, and the tag (`NodeType`) is decorative        |
| Extent is `rect()` gated by `BoundedRectRendering`                       | Partial update needs per-node bounds; an unverified bound is worse than none   | Two ways to be wrong (bad rect, or the flag without the rect); default is "assume full screen"  |
| Antialiasing is generated geometry gated by `supportsAntialiasing()`     | Fidelity decided once, before vertices exist, by the party that can decline it | The fidelity ladder is boolean; there is no "as good as you can manage" middle rung             |

## Bearing on the proposal

1. **The tag must be fine-grained enough to dispatch on, or a backend will
   downcast.** Qt's seven `NodeType`s force a five-way `dynamic_cast` chain in the
   software adaptation. This is F2 and friction §4 arriving from a new direction:
   a `SumType` variant per _semantic_ op (not per geometric shape) is what keeps
   role recovery free. Fold friction §6 into the same change — **the tag is the
   slot**, and `visual` becomes the only styling field.
2. **Contradicts F3's framing.** F3 treats semantic-vs-primitive as a free choice
   about where degradation lives. Qt demonstrates a hard constraint underneath it:
   geometry-plus-shader is portable only among shader backends, and Qt's own CPU
   backend drops it. For a toolkit whose backends are a cell grid and a GPU, the
   semantic tier is not a preference — it is the only shared vocabulary. This also
   caps how far `sparkles:ui` should drift toward egui's mesh model.
3. **Complicates F7 and re-frames friction §8.** Two questions were conflated.
   Scene extent belongs to the surface (F7 stands). Per-op extent belongs to the
   op, and `DrawOp` half-answers it: `textRun.rect.width` is a cell advance, which
   is a bound only under the monospace assumption friction §1 already indicts. Qt's
   shape — a bound that is only trusted when the op declares it trustworthy — is
   the cheap fix, and it is what an offscreen consumer actually needs.
4. **A declared escape hatch is better than an optional method.** `QSGRenderNode`
   is what `sparkles:ui` lacks for the Skia backend's raw-Graphite path: an op
   that says "I will paint inside this rect, I will dirty this state, do not
   assume anything else". Cheaper than widening the primitive vocabulary each time
   a backend wants more.
5. **Adopt `supportsAntialiasing()`'s shape for F4/F5.** A fidelity request the
   backend may decline, resolved once at build time rather than probed at each
   call site, is the "refusable degrade" F4 wants and the "name a fidelity"
   F5 wants, in one mechanism `sparkles:ui` can express as a DbI optional
   predicate rather than a `__traits(compiles)` at the call site.
6. **Reject the silent skip.** `// We dont know, so skip` is what
   `__traits(compiles)`-per-call-site already does to us in a nicer syntax.
   Whatever replaces `isCanvas` should make an unhandled op a compile error, not a
   missing pixel.
7. **Do not adopt retention.** Batching and partial update are the only things it
   buys, `sparkles:ui` wants neither, and the bill — ownership flags, dirty bits,
   a documented-only thread rendezvous — is exactly the complexity the friction
   log is trying to remove. Take the _phase_ idea from Q7 (a declared window in
   which borrowing is legal) without the tree.

## Sources

- **Core API** — [`qsgnode.h`][qsgnode] (`NodeType`, `Flag`, `DirtyStateBit`, `QSGGeometryNode`, `QSGClipNode`, `QSGOpacityNode`); [`qsgmaterial.h`][qsgmaterial] + [`qsgmaterial.cpp`][qsgmaterialcpp] (`createShader`, `compare` and its batching rationale); [`qsggeometry.h`][qsggeometry]; [`qsgrendernode.h`][rendernode] + [`qsgrendernode.cpp`][rendernodecpp] (`RenderingFlag`, `rect()`); [`qsgrendererinterface.h`][qsgri]; [`qsgbatchrenderer_p.h`][batch].
- **The adaptation seam** — [`qsgcontext_p.h`][qsgcontext] (the private factory); [`qsgadaptationlayer_p.h`][adapt] (`QSGInternalRectangleNode`, `QSGGlyphNode`, `QSGInternalImageNode`, `QSGPainterNode`); [`qsgbasicinternalrectanglenode_p.h`][rectnodep] + [`.cpp`][rectnode] (`supportsAntialiasing()`).
- **The software adaptation** — [`qsgsoftwarerenderablenodeupdater.cpp`][swupd] (the downcast ladder and the silent skip); [`qsgsoftwarecontext.cpp`][swcontext] (`processTextRenderType`).
- **Public semantic nodes** — [`qsgtextnode.h`][qsgtextnode], [`qsgrectanglenode.h`][qsgrectnode], [`qsgimagenode.h`][qsgimagenode].
- **Items** — [`qquicktext_p_p.h`][qqtextpp] + [`qquicktext.cpp`][qqtext] (who measures); [`qquickitem.h`][qquickitem] (`updatePaintNode`); [`qquickpainteditem.h`][painteditem] (the `QPainter` escape hatch).
- **qtbase** — [`qrhi.h`][qrhi] (`Implementation`, `Feature`, `ResourceLimit`, `isFeatureSupported`).
- **Rationale quoted above** — [`scenegraph.qdoc`][qdoc-sg] and [`adaptations.qdoc`][qdoc-adapt], rendered as [Qt Quick Scene Graph][doc-sg] and [Scene Graph Adaptations][doc-adapt].

Revisions were pinned with `git -C <clone> rev-parse HEAD` against the GitHub
mirrors `qt/qtdeclarative` and `qt/qtbase`; every cited path was verified with
`git cat-file -e <sha>:<path>`.

<!-- References -->

[qd-rev]: https://github.com/qt/qtdeclarative/tree/ffc46f28ab21b6666dbea46c81cf2726ce682419
[qb-rev]: https://github.com/qt/qtbase/tree/d0787745aa43e5baf49de876f917946df6aceca5
[doc-sg]: https://doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html
[doc-adapt]: https://doc.qt.io/qt-6/qtquick-visualcanvas-adaptations.html
[qsgnode]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/coreapi/qsgnode.h
[qsgmaterial]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/coreapi/qsgmaterial.h
[qsgmaterialcpp]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/coreapi/qsgmaterial.cpp
[qsggeometry]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/coreapi/qsggeometry.h
[rendernode]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/coreapi/qsgrendernode.h
[rendernodecpp]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/coreapi/qsgrendernode.cpp
[qsgri]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/coreapi/qsgrendererinterface.h
[batch]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/coreapi/qsgbatchrenderer_p.h
[qsgcontext]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/qsgcontext_p.h
[adapt]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/qsgadaptationlayer_p.h
[swupd]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/adaptations/software/qsgsoftwarerenderablenodeupdater.cpp
[swcontext]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/adaptations/software/qsgsoftwarecontext.cpp
[qsgtextnode]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/util/qsgtextnode.h
[qsgrectnode]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/util/qsgrectanglenode.h
[qsgimagenode]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/util/qsgimagenode.h
[rectnodep]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/qsgbasicinternalrectanglenode_p.h
[rectnode]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/scenegraph/qsgbasicinternalrectanglenode.cpp
[qqtextpp]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/items/qquicktext_p_p.h
[qqtext]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/items/qquicktext.cpp
[qquickitem]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/items/qquickitem.h
[painteditem]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/items/qquickpainteditem.h
[qdoc-sg]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/doc/src/concepts/visualcanvas/scenegraph.qdoc
[qdoc-adapt]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/doc/src/concepts/visualcanvas/adaptations.qdoc
[qrhi]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/rhi/qrhi.h
