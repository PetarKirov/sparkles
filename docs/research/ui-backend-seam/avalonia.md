# Avalonia `IDrawingContextImpl` — a primitive seam with capabilities declared at four different scopes

**Category:** multi-backend toolkit seam. **Last reviewed:** August 23, 2026.
Pinned at [`aee3f685`][rev].

A shipping .NET toolkit whose renderer seam is close to `sparkles:ui` in size —
one abstract platform painter, twenty-seven methods, two live backends — and
the only surveyed subject that both **reifies its command stream as typed
nodes** and **declares its backend capabilities explicitly**, which are the two
halves of [`canvas-seam-friction.md`][friction] §2 and §4.

| Field                                 | Value                                                                                                                                                 |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**                          | C# (.NET)                                                                                                                                             |
| **License**                           | MIT ([`licence.md`][licence])                                                                                                                         |
| **Repository**                        | [`AvaloniaUI/Avalonia`][repo]                                                                                                                         |
| **Documentation**                     | [docs.avaloniaui.net][docs]                                                                                                                           |
| **Category**                          | multi-backend toolkit seam                                                                                                                            |
| **Pinned revision**                   | [`aee3f68551b0ac4417e32996a6627f34462edbc3`][rev]                                                                                                     |
| **Target range**                      | desktop (Win32, X11, macOS), mobile (Android, iOS), browser (WASM), headless                                                                          |
| **Backends shipped at this revision** | Skia ([`src/Skia/Avalonia.Skia`][skia-pri]) and headless ([`src/Headless/Avalonia.Headless`][headless]) only — no Direct2D backend exists in the tree |
| **Seam declaration**                  | [`src/Avalonia.Base/Platform/IDrawingContextImpl.cs`][idci]                                                                                           |

> [!NOTE]
> The Direct2D backend that historically sat beside Skia is **not present** at
> the pinned revision: `src/Windows/` holds only `Avalonia.Win32`,
> `Avalonia.Win32.Automation` and `Avalonia.Win32.Interoperability`. The
> capability surface Direct2D motivated outlived it — `CreateLayer`'s doc
> comment in [`IDrawingContextImpl.cs`][idci] still justifies itself by saying
> "the Direct2D backend has to do a format conversion each time a standard
> render target bitmap is rendered". Statements below about "two backends" are
> statements about this revision.

## Overview

### What it solves

Avalonia separates the drawing API an application writes against
(`Avalonia.Media.DrawingContext`, a public abstract class) from the drawing API
a platform implements (`Avalonia.Platform.IDrawingContextImpl`). A control's
`Render(DrawingContext)` never sees a backend. Between the two sits a
**recorder**: [`RenderDataDrawingContext`][renderdata-ctx] is a `DrawingContext`
subclass that turns calls into a tree of typed `IRenderDataItem` nodes, which is
serialised to a compositor thread and replayed there against the real
`IDrawingContextImpl`. So the seam is crossed twice — once by the recorder that
produces values, once by the replayer that consumes them.

### Design philosophy

The seam is explicitly unstable and explicitly private. Both interfaces carry
metadata attributes saying so:

```csharp
/// <summary>
/// Defines the interface through which drawing occurs.
/// </summary>
[Unstable]
public interface IDrawingContextImpl : IDisposable
```

— [`IDrawingContextImpl.cs`][idci]

[`IPlatformRenderInterface`][ipri] carries `[Unstable, PrivateApi]` likewise.
That is the load-bearing decision. Because the seam is not public API, Avalonia
can add a method to it (`DrawRegion`, `PushTextOptions`) without a deprecation
cycle, and therefore has **no optional core methods at all**: every one of
`IDrawingContextImpl`'s twenty-seven methods is mandatory. Optionality is
expressed only outside the core interface, by the separate mechanisms tabulated
under Q2 below.

## How it works

`IDrawingContextImpl` declares one settable property (`Matrix Transform`) and
twenty-seven methods. Eight of them draw:

```csharp
void Clear(Color color);
void DrawBitmap(IBitmapImpl source, double opacity, Rect sourceRect, Rect destRect);
void DrawLine(IPen? pen, Point p1, Point p2);
void DrawGeometry(IBrush? brush, IPen? pen, IGeometryImpl geometry);
void DrawRectangle(IBrush? brush, IPen? pen, RoundedRect rect, BoxShadows boxShadows = default);
void DrawRegion(IBrush? brush, IPen? pen, IPlatformRenderInterfaceRegion region);
void DrawEllipse(IBrush? brush, IPen? pen, Rect rect);
void DrawGlyphRun(IBrush? foreground, IGlyphRunImpl glyphRun);
```

The remaining nineteen are eight `Push`/`Pop` pairs (`Clip` ×3 overloads,
`Layer`, `Opacity`, `OpacityMask`, `GeometryClip`, `RenderOptions`,
`TextOptions`), `CreateLayer`, and `GetFeature`. There is no `Measure`, no
`FillRect`, no text-string entry point — `DrawGlyphRun` takes an already-shaped
`IGlyphRunImpl`.

The command stream is reified as **one class per operation**, not as a tagged
record. The contract every node satisfies is three members wide:

```csharp
interface IRenderDataItem
{
    void Invoke(ref RenderDataNodeRenderContext context); // render to a drawing context
    Rect? Bounds { get; }                                 // visible content, global coords
    bool HitTest(Point p);                                // this node's geometry only
}
```

— [`RenderDataNodes.cs`][nodes]

Nine node classes implement it (`RenderDataRectangleNode`,
`RenderDataGlyphRunNode`, `RenderDataLineNode`, `RenderDataEllipseNode`,
`RenderDataGeometryNode`, `RenderDataBitmapNode`, `RenderDataCustomNode`, plus
the `RenderDataPushNode` family for the push/pop pairs). Each carries **only the
fields its operation uses**, and each supplies its own `Bounds` and `HitTest`:

```csharp
class RenderDataRectangleNode : RenderDataBrushAndPenNode
{
    public RoundedRect Rect { get; set; }
    public BoxShadows BoxShadows { get; set; }

    public override void Invoke(ref RenderDataNodeRenderContext context) =>
        context.Context.DrawRectangle(ServerBrush, ServerPen, Rect, BoxShadows);

    public override Rect? Bounds => BoxShadows.TransformBounds(Rect.Rect).Inflate((ServerPen?.Thickness ?? 0) / 2);
}
```

— [`RenderDataRectangleNode.cs`][node-rect]

`RenderDataPushNode` owns a `PooledInlineList<IRenderDataItem> Children` and
brackets them, so the stream is a **tree**, not a flat list with balance
obligations — a `Push` with no children is skipped entirely
(`if (Children.Count == 0) return;`).

## Q1 — measurement units, and who answers

**Not on the painter, and not even on one interface.** Text reaches
`IDrawingContextImpl` only as `IGlyphRunImpl`, an "immutable platform
representation" that already knows its own `Bounds`, `BaselineOrigin` and
`FontRenderingEmSize` ([`IGlyphRunImpl.cs`][iglyphrun]). Producing it is a
three-interface job that the drawing context has no part in:

- [`IFontManagerImpl`][ifontmgr] — family enumeration, `TryCreateGlyphTypeface`,
  and `TryMatchCharacter(int codepoint, …, out IPlatformTypeface)`, i.e. font
  fallback per codepoint.
- [`ITextShaperImpl`][itextshaper] — `ShapedBuffer ShapeText(ReadOnlyMemory<char> text, TextShaperOptions options)`.
- `IPlatformRenderInterface.CreateGlyphRun(GlyphTypeface, double fontRenderingEmSize, IReadOnlyList<GlyphInfo>, Point baselineOrigin)`
  ([`IPlatformRenderInterface.cs`][ipri]) — the shaped result becomes a platform
  glyph run.

The unit is a `double` in device-independent pixels throughout; there is no
per-backend length type as in Slint. The measurement API a control uses,
`FormattedText`, exposes `Width`, `Height`, `Baseline`, `Extent`,
`OverhangLeading`/`OverhangTrailing` and `WidthIncludingTrailingWhitespace`
— and computes them by running the _draw_ path with a null painter:

```csharp
_metrics = DrawAndCalculateMetrics(
    null,           // drawing context
    new Point(),    // drawing offset
    true);          // calculate black box metrics
```

— [`FormattedText.cs`][formattedtext]

That is the sharpest statement of F1 in the survey: measuring is drawing with
the backend removed, which is only possible because the backend contributes
nothing to the answer.

The headless backend proves the same point from the other side. It stubs every
geometry, bitmap and drawing call to a no-op, but it **cannot stub the font** —
it ships a real TrueType file, `BareMinimum.ttf`, and loads it as the default
typeface ([`HeadlessPlatformStubs.cs`][headless-stubs]):

```csharp
var defaultFontUri = new Uri("resm:Avalonia.Headless.BareMinimum.ttf?assembly=Avalonia.Headless");
```

A backend may be free of pixels; it is not free of metrics. Friction §1 has our
`SkiaCanvas.measure` discarding Skia and returning `cellsOf(text)`; Avalonia's
equivalent question never reaches a canvas.

## Q2 — is the contract stated in one place?

**No — it is stated in four places, at four different scopes, and that is
deliberate.** This is the subject's most transferable finding and it
_complicates_ [F4](./comparison.md).

| Scope                        | Mechanism                                | Declared where                         | Example                                                                                                                                    |
| ---------------------------- | ---------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Whole platform, static       | `bool` / enum properties on an interface | [`IPlatformRenderInterface`][ipri]     | `SupportsIndividualRoundRects`, `SupportsRegions`, `DefaultPixelFormat`, `DefaultAlphaFormat`, `IsSupportedBitmapPixelFormat(PixelFormat)` |
| Graphics context, runtime    | `object? TryGetFeature(Type)`            | [`IOptionalFeatureProvider`][ifeature] | `IExternalObjectsHandleWrapRenderInterfaceContextFeature`                                                                                  |
| One render target, per-frame | `readonly struct` of `init` booleans     | [`RenderTargetProperties.cs`][rtprops] | `RetainsPreviousFrameContents`, `IsSuitableForDirectRendering`, `PreviousFrameIsRetained`                                                  |
| One drawing context          | optional interface + `GetFeature(Type)`  | [`IDrawingContextImpl`][idci]          | `IDrawingContextWithAcrylicLikeSupport`, `IDrawingContextImplWithEffects`, `ISkiaSharpApiLeaseFeature`                                     |

The static tier is a genuine declared capability set in Qt's sense, and it is
consumed by name, not probed. `BorderRenderHelper` asks once and caches the
answer, then chooses between a fast path and building retained geometry:

```csharp
_backendSupportsIndividualCorners ??= AvaloniaLocator.Current.GetRequiredService<IPlatformRenderInterface>()
    .SupportsIndividualRoundRects;
…
if (borderThickness.IsUniform &&
    (cornerRadius.IsUniform || _backendSupportsIndividualCorners == true) &&
    backgroundSizing == BackgroundSizing.CenterBorder)
```

— [`BorderRenderHelper.cs`][borderhelper]

The interface's own doc comment states the contract for the _caller_, not the
implementor: "Some platform renderers can't directly handle rounded corners on
rectangles. In this case, code that requires rounded corners must generate and
retain a geometry instead." ([`IPlatformRenderInterface.cs`][ipri]) The two
shipped backends answer differently — Skia `=> true`
([`PlatformRenderInterface.cs`][skia-pri]), headless `=> false`
([`HeadlessPlatformRenderInterface.cs`][headless-pri]) — so the fallback path is
exercised by the test backend on every headless run. That is the property
`RecordingCanvas` gives us and the reason it pays for itself.

The escape-hatch tier is the closest analogue of our `__traits(compiles)`
probing, and it is deliberately _not_ free-form: `GetFeature` is keyed by a
declared feature interface, so the probeable set is enumerable by grepping for
implementations. Skia's whole answer is one comparison against
`typeof(ISkiaSharpApiLeaseFeature)`, returning `null` otherwise
([`DrawingContextImpl.cs`][skia-dci]).

> [!IMPORTANT]
> The lesson for friction §2 is not "declare your capabilities" but
> **"a capability has a scope"**. `pushClip` is a property of a canvas type;
> "does this surface retain last frame" is a property of one render target on
> one frame. `sparkles:ui` currently has one undifferentiated optional bucket
> and no vocabulary for the difference.

## Q3 — semantic or primitive operations?

**Primitive in the core, semantic through optional interfaces.** There is no
`DrawScrollBar`. Avalonia's `ScrollBar` is a templated control that renders as
borders and rectangles like anything else, and the seam never learns it existed.

But the seam is not purely geometric either. `DrawRectangle` takes a
`RoundedRect` and a `BoxShadows` — both semantic in exactly Slint's sense: the
backend is told a shadow was intended rather than handed the blurred geometry.
And the one genuinely semantic material, acrylic, enters as an **optional
interface with a framework-level fallback**:

```csharp
public void DrawRectangle(IExperimentalAcrylicMaterial material, RoundedRect rect)
{
    if (_impl is IDrawingContextWithAcrylicLikeSupport idc)
        idc.DrawRectangle(material, rect);
    else
        DrawRectangle(new ImmutableSolidColorBrush(material.FallbackColor), null, rect);
}
```

— [`PlatformDrawingContext.cs`][platformctx]

Three things are worth taking from those six lines. The degradation lives
**once, in the framework** — Qt's camp in [F3](./comparison.md), not Slint's.
The fallback is **carried by the semantic value itself**
(`material.FallbackColor`), so the framework need not invent an approximation.
And the semantic operation **is not in the core interface at all**: a new
backend implements `IDrawingContextImpl` and gets acrylic-as-solid-colour free.

That is a direct answer to friction §3. Our `scrollbar` op forces every backend
to know what a scrollbar is because the degradation is the backend's job. The
Avalonia shape would be: keep the semantic op, put it behind an optional
interface, give the semantic payload a declared degradation, and perform that
degradation in the interpreter once.

The corresponding extension point for applications is `ICustomDrawOperation`,
which requires the caller to supply exactly the things `IRenderDataItem`
requires — `Rect Bounds`, `bool HitTest(Point)`, `void Render(ImmediateDrawingContext)`
([`CustomDrawOperation.cs`][customop]). A custom op is a node like any other.

## Q4 — command shape

**A polymorphic class per operation, not a tag plus fields.** Nine node types
share a three-member interface; `RenderDataRectangleNode` has exactly `Rect` and
`BoxShadows` beyond its brush/pen base, `RenderDataLineNode` has exactly `P1`
and `P2`, `RenderDataGlyphRunNode` has exactly a glyph-run reference. There is
no `DrawOp` with eighteen fields and no `OpKind` enum over the drawing verbs.

This confirms [F2](./comparison.md)
from a second, independent direction: egui reifies as a Rust `enum Shape`,
Avalonia reifies as a C# class hierarchy, and neither reaches for tag-plus-dead-
fields. It also **complicates** F2's recommended fix. A `SumType` is the D
analogue of egui's `enum`, but the property Avalonia buys with dispatch is one a
sum type does not give for free: every node answers `Bounds` and `HitTest`
_itself_, so adding an operation cannot forget to teach the extent and hit-test
walkers about it. In D, that is a `final switch` over a sum type — which the
compiler does enforce — so the property is recoverable, but only if the extent
query is written as an exhaustive switch rather than as `if (op.kind == …)`
chains.

One place Avalonia _does_ use tag-plus-union is instructive about when that
encoding is correct: the compositor's deferred state stack stores pending
push/pop commands as a `PendingCommandType` enum plus two
`[StructLayout(LayoutKind.Explicit)]` unions of overlapping fields
([`DrawingContextProxy.PendingCommands.cs`][pending]) — an internal,
short-lived buffer whose job is to be discarded without ever being replayed,
the one case where dead fields cost nothing because nobody reads the wrong one.

## Q5 — sub-unit placement

**Does not arise.** Coordinates are `double` device-independent pixels
throughout; `Rect`, `Point`, `RoundedRect` and `Matrix` are all continuous, and
device pixels appear only at surface boundaries as `PixelSize`. The framework's
answer to pixel snapping is a _layout_ pass, not a drawing vocabulary:
`LayoutHelper.RoundLayoutValue`/`RoundLayoutSizeUp`/`RoundLayoutThickness` take
an explicit `dpiScale` and are applied when a parent has layout rounding enabled
([`LayoutHelper.cs`][layouthelper]).

This is the third subject in a row to dissolve friction §5 by having continuous
coordinates, and it adds one detail the others do not: the snapping is
**parameterised by the scale factor and performed above the seam**, so the
painter is never asked where a hairline goes. `RuleEdge` has no counterpart
because the question has already been answered in DIPs by the time drawing
starts.

## Q6 — resolved appearance, semantic role, or both?

**Both, but along a different axis than ours — and the duplication is real.**
Every brush/pen node carries two references to the same styling:

```csharp
abstract class RenderDataBrushAndPenNode : IRenderDataItemWithServerResources
{
    public IBrush? ServerBrush { get; set; }
    public IPen? ServerPen { get; set; }
    public IPen? ClientPen { get; set; }
```

— [`RenderDataNodes.cs`][nodes]

`ServerBrush`/`ServerPen` come from `brush.GetServer(_compositor)` — the
render-thread resolved resource, used by `Invoke` and by `Bounds`. `ClientPen`
is the original UI-thread object, used by `HitTest`
([`RenderDataDrawingContext.cs`][renderdata-ctx],
[`RenderDataLineNode.cs`][node-line]). So the duplication is not
_semantic role_ versus _resolved appearance_; it is **the same appearance held
at two thread affinities**, because the two consumers of a node run on different
threads.

Friction §6 says our seam "hedges rather than deciding" by carrying `visual` and
`slot`. Avalonia hedges too, and pays the same per-op cost — but its second
field buys thread-safe hit testing, a capability, rather than serving a second
backend. The question friction §6 should ask is therefore sharper than "which
one?": _what does the second field buy, and is that thing a capability or a
consumer?_ If the HTML interpreter is the only consumer of `slot`, it is a
consumer and the cost is misplaced; if `slot` were what makes a display list
re-themeable without re-layout, it is a capability and it is earning its space.

## Q7 — payload ownership

**Reference-counted, with an explicit handoff.** Glyph runs are the model case:

```csharp
public IRef<IGlyphRunImpl>? GlyphRun { get; set; }
```

— [`RenderDataGlyphRunNode.cs`][node-glyph]

`IRef<out T>` is "a ref-counted wrapper for a disposable object" with `Clone()`,
`IsAlive` and `RefCount` ([`Ref.cs`][ref]), and the recorder increments on
capture: `GlyphRun = glyphRun.PlatformImpl.Clone()`.

Nothing is borrowed for the duration of a call. Commands are explicitly built to
**outlive the frame and cross a thread**: `CompositionRenderData.SerializeChanges`
writes the node objects into a `BatchStreamWriter` and marks `_itemsSent = true`,
after which the client side no longer disposes them
([`CompositionRenderData.cs`][renderdata]) — an ownership transfer, spelled out
in one flag.

This is [F6](./comparison.md)
confirmed and extended. Friction §7 notes that "a GPU backend that wants to
record on one thread and submit on another meets it immediately"; Avalonia's
entire architecture is that arrangement, and it cost a refcounted handle type
plus a transfer flag, not an interning table.

## Q8 — can a backend ask the scene its extent?

**Yes, in both directions, and this contradicts
[F7](./comparison.md).**

Scene → extent: every node declares `Rect? Bounds`, and the recorded list folds
them:

```csharp
private LtrbRect? CalculateRenderBounds()
{
    LtrbRect? totalBounds = null;
    foreach (var item in _items)
        totalBounds = LtrbRect.FullUnion(totalBounds, item.Bounds);

    return ApplyRenderBoundsRounding(totalBounds);
}
```

— [`ServerCompositionRenderData.cs`][servrenderdata]

The result is cached behind a `_boundsValid` flag and rounded outward
(`Math.Floor`/`Math.Ceiling`). This is the same scan `skia-canvas-render.d` had
to write by hand in friction §8 — except it is a first-class, cached, per-node
API rather than a caller reaching into `rect` fields, and it is what makes
`ISceneBrushContent.Rect` ([`ISceneBrush.cs`][scenebrush]) possible: recorded
content used as a brush must know its own extent.

Scene → surface: the extent also flows _forward_. `IRenderTarget.CreateDrawingContext`
takes the scene's size as a parameter:

```csharp
/// <param name="sceneInfo">Information about the scene that's about to be rendered into this render target.
/// This is expected to be reported to the underlying platform and affect the framebuffer size, however
/// the implementation may choose to ignore that information.
/// </param>
IDrawingContextImpl CreateDrawingContext(RenderTargetSceneInfo sceneInfo, out RenderTargetDrawingContextProperties properties);

public record struct RenderTargetSceneInfo(PixelSize Size, double Scaling, Size LogicalSize);
```

— [`IRenderTarget.cs`][irt]

F7 concluded that "a backend allocating a surface generally knows the size
because it chose it". Avalonia inverts that: the _scene_ proposes a size, the
surface may decline, and the answer comes back as
`RenderTargetDrawingContextProperties` on the same call. That the parameter
carries `PixelSize`, `Scaling` **and** `LogicalSize` together is the detail worth
copying — extent without its scale is not actionable at a seam that spans units.

## Strengths

- **Optionality has a type.** `GetFeature(Type)` returning a declared feature
  interface makes the probeable surface enumerable, unlike an untyped
  `__traits(compiles)` probe at a call site.
- **Capabilities are scoped.** Platform-static, context-runtime, per-target and
  per-context tiers each answer a question with the right lifetime.
- **One field per operation.** Nine node classes with no dead fields, each
  supplying its own `Bounds` and `HitTest`, so extending the stream cannot leave
  the extent or hit-test walker behind.
- **Ownership is explicit end-to-end.** `IRef<T>` plus a serialisation handoff
  makes "this command outlives the frame and changes thread" a stated property.
- **Semantic operations arrive without widening the core**, and **the test
  backend exercises the fallback paths** — headless answers `false` to
  `SupportsIndividualRoundRects` and `SupportsRegions`, so the geometry fallback
  is not dead code.

## Weaknesses

- **The seam is unstable by declaration.** `[Unstable]`/`[PrivateApi]` is what
  makes twenty-seven mandatory methods tolerable; a toolkit that promises a
  stable backend API cannot buy that freedom.
- **Twenty-seven mandatory methods is a real cost.** The headless backend is
  ~180 lines of empty bodies, most of which exist only to satisfy the interface.
- **Four capability mechanisms is three more than a reader wants.** Finding out
  what a backend must support means reading an interface, a struct, a feature
  registry and a set of optional interfaces.
- **The `ServerBrush`/`ClientPen` duplication is per-node and unavoidable**, and
  the reason (thread affinity of the hit tester) is documented nowhere near the
  fields.

## Key design decisions and trade-offs

| Decision                                                                          | Rationale                                                                             | Trade-off                                                                                                           |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Mark the platform seam `[Unstable]`/`[PrivateApi]`                                | Lets the interface grow (`DrawRegion`, `PushTextOptions`) without deprecation cycles  | Third-party backends are not a supported scenario; only in-tree backends track the churn                            |
| No optional methods on `IDrawingContextImpl`                                      | A backend author reads one file and knows the whole obligation                        | Every backend implements every method, including the ones it will only ever no-op                                   |
| Declare static capabilities as properties on `IPlatformRenderInterface`           | Callers can choose an algorithm once and cache it (`BorderRenderHelper`)              | Capability granularity is fixed at compile time; a backend cannot vary it per surface                               |
| Route runtime/per-frame capabilities through `TryGetFeature` and property structs | A capability whose lifetime is a frame cannot be a static boolean                     | Four mechanisms to learn instead of one                                                                             |
| One class per drawing operation, with `Bounds` + `HitTest` on each                | Hit testing and extent are derivable from the stream without a parallel structure     | Allocation per command; pooling (`PooledInlineList`, `ThreadSafeObjectPool`) becomes mandatory rather than optional |
| Semantic ops (acrylic) as optional interfaces with framework fallbacks            | The degradation exists once and is driven by the semantic value's own `FallbackColor` | Discovering that acrylic exists requires knowing to look for `IDrawingContextWithAcrylicLikeSupport`                |
| Ref-count payloads (`IRef<T>`) and transfer ownership at serialisation            | Commands legitimately outlive the frame and change thread                             | Every payload capture is a refcount operation; disposal correctness is a runtime property                           |
| Text never enters the seam unshaped                                               | The painter is not a party to measurement; `DrawGlyphRun` is trivially portable       | A backend cannot apply its own shaping optimisations; the headless backend must still ship a real font              |

## Bearing on the proposal

1. **A capability has a scope; say which.** Friction §2 asks for the contract to
   be stated. Avalonia shows that one statement is not enough: split
   `sparkles:ui`'s single optional bucket into _type-level_ (does this canvas
   have `pushClip`?) and _instance/frame-level_ (does this surface retain the
   previous frame? what is its scale?). This **complicates F4**, which framed the
   fix as "a floor plus a negotiable set" — the missing axis is lifetime, not
   just severity.
2. **Give optional probes a declared type.** Replace bare `__traits(compiles)` at
   interpreter call sites with named capability traits or a `getFeature`-style
   lookup keyed by a declared type, so the probeable surface is enumerable from
   one place. This is the cheap half of §2 and does not require abandoning
   structural typing.
3. **Keep `scrollbar` semantic, but move its degradation into the interpreter and
   let the op carry its own fallback.** Avalonia's acrylic path — optional
   interface, framework-level degrade, fallback carried by the value — is the
   shape friction §3 is groping for. It removes seven of `DrawOp`'s eight
   scrollbar fields from every backend's concern without removing the semantics.
4. **When re-encoding `DrawOp` as a sum type (F2), make extent and hit testing
   exhaustive switches over it.** Avalonia gets "you cannot add an operation and
   forget its bounds" from virtual dispatch; D gets the same guarantee from
   `final switch`, but only if the extent query is written that way. This is the
   part of F2 the recommendation currently leaves implicit.
5. **F7 is wrong as stated — a scene-side extent query is normal, and it should
   carry scale.** Avalonia computes a cached `Bounds` by unioning per-node
   bounds, uses it for scene brushes, _and_ passes
   `RenderTargetSceneInfo(PixelSize, Scaling, LogicalSize)` forward to the
   surface. Friction §8's hand-rolled scan in `skia-canvas-render.d` is not a
   symptom of asking the wrong question; it is the right query, unimplemented.
6. **`IRef`-style refcounting is the confirmed answer to §7, and the handoff must
   be explicit.** `SerializeChanges`' `_itemsSent` flag is a one-bit ownership
   transfer between threads — exactly what M7/T5's record-here-submit-there plan
   needs, and cheaper than interning.
7. **Test-backend divergence is a feature.** Headless answering `false` where
   Skia answers `true` keeps the fallback paths live. `RecordingCanvas` should
   deliberately _decline_ some optional capabilities rather than implementing
   everything, so the degradation paths are exercised by the reference backend.
8. **Do not copy the `[Unstable]` bargain unless the same freedom is wanted.**
   Twenty-seven mandatory methods is affordable only because Avalonia can change
   the interface at will; `sparkles:ui`'s optional-primitive bargain is the right
   trade for a seam outside code may implement.

## Sources

- [`src/Avalonia.Base/Platform/IDrawingContextImpl.cs`][idci] — the seam: 27 methods, `Transform`, `GetFeature`, plus `IDrawingContextImplWithEffects` and `IDrawingContextLayerImpl`.
- [`src/Avalonia.Base/Platform/IPlatformRenderInterface.cs`][ipri] — the declared capability set (`SupportsIndividualRoundRects`, `SupportsRegions`, `DefaultPixelFormat`, `DefaultAlphaFormat`) and the resource factories, incl. `CreateGlyphRun`; `IPlatformRenderInterfaceContext` and `MaxOffscreenRenderTargetPixelSize`.
- [`src/Avalonia.Base/Platform/ITextShaperImpl.cs`][itextshaper], [`IFontManagerImpl.cs`][ifontmgr], [`IGlyphRunImpl.cs`][iglyphrun] — the three-interface text stack that never touches the painter.
- [`src/Avalonia.Base/Media/FormattedText.cs`][formattedtext] — `DrawAndCalculateMetrics(null, …)`; `Width`/`Height`/`Baseline`/`Extent`.
- [`src/Avalonia.Base/Media/DrawingContext.cs`][drawingctx] — the public abstract painter, its `*Core` template methods and the `PushedState` RAII pair.
- [`src/Avalonia.Base/Media/PlatformDrawingContext.cs`][platformctx], [`IDrawingContextWithAcrylicLikeSupport.cs`][acrylic] and [`ServerCompositionExperimentalAcrylicVisual.cs`][acrylicvisual] — a semantic op behind an optional interface, degrading to `material.FallbackColor`.
- [`src/Avalonia.Base/Rendering/Composition/Drawing/Nodes/RenderDataNodes.cs`][nodes], [`RenderDataRectangleNode.cs`][node-rect], [`RenderDataGlyphRunNode.cs`][node-glyph], [`RenderDataLineNode.cs`][node-line] — the reified command stream as typed nodes.
- [`src/Avalonia.Base/Rendering/Composition/Drawing/RenderDataDrawingContext.cs`][renderdata-ctx] — the recorder; `GetServer`, `ClientPen`, `PlatformImpl.Clone()`.
- [`src/Avalonia.Base/Rendering/Composition/Drawing/CompositionRenderData.cs`][renderdata] and [`ServerCompositionRenderData.cs`][servrenderdata] — the cross-thread handoff and the cached extent union.
- [`src/Avalonia.Base/Rendering/Composition/Server/DrawingContextProxy.PendingCommands.cs`][pending] — the one place a tag-plus-union encoding is used, and why.
- [`src/Avalonia.Base/Platform/IRenderTarget.cs`][irt] and [`RenderTargetProperties.cs`][rtprops] — `RenderTargetSceneInfo`; per-target and per-frame capability structs.
- [`src/Avalonia.Base/Utilities/Ref.cs`][ref], [`IOptionalFeatureProvider.cs`][ifeature], [`Rendering/SceneGraph/CustomDrawOperation.cs`][customop], [`Media/ISceneBrush.cs`][scenebrush].
- [`src/Avalonia.Controls/Utils/BorderRenderHelper.cs`][borderhelper] — the only in-tree consumer of `SupportsIndividualRoundRects`.
- [`src/Skia/Avalonia.Skia/PlatformRenderInterface.cs`][skia-pri], [`DrawingContextImpl.cs`][skia-dci], [`src/Headless/Avalonia.Headless/HeadlessPlatformRenderInterface.cs`][headless-pri], [`HeadlessPlatformStubs.cs`][headless-stubs] — the two shipped backends.
- [`src/Avalonia.Base/Layout/LayoutHelper.cs`][layouthelper] — DPI-scaled layout rounding, above the seam.

Revision pinned with `git rev-parse HEAD` against a local clone of
[`AvaloniaUI/Avalonia`][repo]; every cited path verified present at that SHA
with `git cat-file -e <sha>:<path>`.

<!-- References -->

[rev]: https://github.com/AvaloniaUI/Avalonia/tree/aee3f68551b0ac4417e32996a6627f34462edbc3
[repo]: https://github.com/AvaloniaUI/Avalonia
[docs]: https://docs.avaloniaui.net/
[licence]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/licence.md
[idci]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Platform/IDrawingContextImpl.cs
[ipri]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Platform/IPlatformRenderInterface.cs
[itextshaper]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Platform/ITextShaperImpl.cs
[ifontmgr]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Platform/IFontManagerImpl.cs
[iglyphrun]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Platform/IGlyphRunImpl.cs
[acrylic]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Platform/IDrawingContextWithAcrylicLikeSupport.cs
[acrylicvisual]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/Composition/Server/ServerCompositionExperimentalAcrylicVisual.cs
[irt]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Platform/IRenderTarget.cs
[rtprops]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Platform/RenderTargetProperties.cs
[ifeature]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/IOptionalFeatureProvider.cs
[drawingctx]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Media/DrawingContext.cs
[platformctx]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Media/PlatformDrawingContext.cs
[formattedtext]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Media/FormattedText.cs
[scenebrush]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Media/ISceneBrush.cs
[customop]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/SceneGraph/CustomDrawOperation.cs
[nodes]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/Composition/Drawing/Nodes/RenderDataNodes.cs
[node-rect]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/Composition/Drawing/Nodes/RenderDataRectangleNode.cs
[node-glyph]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/Composition/Drawing/Nodes/RenderDataGlyphRunNode.cs
[node-line]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/Composition/Drawing/Nodes/RenderDataLineNode.cs
[renderdata-ctx]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/Composition/Drawing/RenderDataDrawingContext.cs
[renderdata]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/Composition/Drawing/CompositionRenderData.cs
[servrenderdata]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/Composition/Drawing/ServerCompositionRenderData.cs
[pending]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Rendering/Composition/Server/DrawingContextProxy.PendingCommands.cs
[ref]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Utilities/Ref.cs
[layouthelper]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Layout/LayoutHelper.cs
[borderhelper]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Utils/BorderRenderHelper.cs
[skia-pri]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Skia/Avalonia.Skia/PlatformRenderInterface.cs
[skia-dci]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Skia/Avalonia.Skia/DrawingContextImpl.cs
[headless]: https://github.com/AvaloniaUI/Avalonia/tree/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Headless/Avalonia.Headless
[headless-pri]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Headless/Avalonia.Headless/HeadlessPlatformRenderInterface.cs
[headless-stubs]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Headless/Avalonia.Headless/HeadlessPlatformStubs.cs
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
