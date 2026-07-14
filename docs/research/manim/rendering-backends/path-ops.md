# Path preprocessing (boolean ops, flattening, tessellation)

The geometry-conditioning stage _between_ a vector path and a GPU rasterizer.
None of these is a renderer; they are the transforms that make an arbitrary,
possibly self-intersecting, curved path _fillable_ by a triangle-based GPU
pipeline: **boolean operations** (`skia-pathops`) reduce overlapping contours to
non-overlapping simple ones, **flattening** turns curves into polylines within a
tolerance, and **tessellation** (earcut / Lyon) turns a simple polygon into a
triangle mesh. A CPU [winding-fill][fill] rasterizer (Cairo, Blend2D — see
[`./cpu-vector.md`](./cpu-vector.md)) needs none of this; a GPU that
triangulates ([`./gpu-vector.md`](./gpu-vector.md)) needs all of it.

> [!NOTE]
> This is the practical unpacking of [fill triangulation and winding][fill]. Ear
> clipping requires the boundary to be a _simple_ polygon, so a path with
> holes or self-intersections must be booleaned into simple contours first, then
> its curves flattened, then triangulated. Manim Community's OpenGL fill path
> walks exactly this chain.

---

## skia-pathops (boolean path operations)

`skia-pathops` is the Python wheel wrapping Skia's `SkPathOps` module; it is the
boolean-ops engine both Manim families reach for.

| Field      | Value                                                                          |
| ---------- | ------------------------------------------------------------------------------ |
| Language   | Cython over Skia C++ (`pathops` module)                                        |
| License    | `BSD-3-Clause`                                                                 |
| Repository | [`fonttools/skia-pathops`][pathops-repo]                                       |
| Latest     | `0.9.2` (2026-02-16)                                                           |
| Upstream   | Skia [`include/pathops/SkPathOps.h`][skpathops-h] ([`google/skia`][skia-repo]) |

### What it does

The wheel's own description, verbatim ([fonttools/skia-pathops][pathops-repo]):

> "Python bindings for the Google Skia library's Path Ops module, performing
> boolean operations on paths (intersection, union, difference, xor)."

Manim Community depends on it directly — `skia-pathops` is a declared dependency,
and [`manim/mobject/geometry/boolean_ops.py`][mc-boolean] wraps it to implement
`Union`, `Intersection`, `Difference`, and `Exclusion` mobjects. It is the
`skia-pathops` referenced in [fill triangulation and winding][fill] as the
boolean preprocessing that makes a holey/self-intersecting outline safe to ear-clip.

### The operations

Skia's `SkPathOp` enum enumerates the five booleans, verbatim
([`SkPathOps.h`][skpathops-h]):

```c
kDifference_SkPathOp,        //!< subtract the op path from the first path
kIntersect_SkPathOp,         //!< intersect the two paths
kUnion_SkPathOp,             //!< union (inclusive-or) the two paths
kXOR_SkPathOp,               //!< exclusive-or the two paths
kReverseDifference_SkPathOp, //!< subtract the first path from the op path
```

The `Op()` entry point applies one operation and — crucially for a downstream
filler — guarantees a **non-overlapping** result, verbatim:

> "Set this path to the result of applying the Op to this path and the specified
> path: this = (this op operand). The resulting path will be constructed from
> non-overlapping contours. The curve order is reduced where possible so that
> cubics may be turned into quadratics, and quadratics maybe turned into lines.
> Returns true if operation was able to produce a result; otherwise, result is
> unmodified."

`Simplify()` is the single-path variant that removes self-intersection without a
second operand, verbatim:

> "Return a path with a set of non-overlapping contours that describe the same
> area as the original path. The curve order is reduced where possible so that
> cubics may be turned into quadratics, and quadratics maybe turned into lines."

That "non-overlapping contours" postcondition is precisely what ear clipping
requires — `Simplify()` alone turns a self-intersecting glyph outline into a set
of [simple polygons][fill] a tessellator will accept.

### D-binding path

There is no clean C ABI. `SkPathOps` is Skia C++ (see the [Skia
D-binding notes][skia-gpu]); `skia-pathops` reaches it through Cython, not a C
header. A D consumer would either link Skia and write an `extern "C"` shim over
`Op()`/`Simplify()`, or reimplement boolean ops another way. Alternatives that
_do_ have friendlier surfaces: a pure algorithm port, or sidestepping booleans
entirely by using a [winding-fill rasterizer][fill] (Cairo/Blend2D) that fills
overlapping contours directly — the reason the CPU oracle needs no path-ops stage
at all.

---

## Curve flattening (cubic → polyline)

Tessellators and stencil fills operate on straight edges, so every curve must
first be **flattened**: approximated by a polyline whose deviation from the true
curve stays under a tolerance.

- **Mechanism.** Subdivide with [de Casteljau][decast] until each segment is
  within tolerance (flatness), or step the [Bézier basis][basis] at a fixed
  parameter count. Adaptive subdivision spends vertices only where curvature is
  high. The [`bezier-eval.d`][ex-bezier] probe implements the de Casteljau
  evaluator both flattening strategies rest on.
- **Basis matters.** A [quadratic vs cubic][basis] input changes the flattener:
  TrueType quadratics and CFF/OpenType cubics need normalizing to one basis
  first (the same [glyph-outline][glyph] concern), and a `conicTo`/rational
  quadratic (Skia) flattens differently again.
- **Tolerance is the reproducibility knob.** The flatness threshold determines
  vertex count and therefore the exact mesh; pin it, or two runs (or two
  backends) disagree at the sub-pixel level — the [determinism][cpugpu] caveat in
  miniature.

Both Lyon and `mapbox-earcut`'s callers flatten before they triangulate; NanoVG
flattens before it stencils; Vello flattens on the GPU inside its compute
pipeline.

---

## Tessellation (earcut / Lyon)

Once a fill region is a set of simple, flattened polygons, **tessellation** turns
it into the triangle mesh a GPU draws. This is the (b) branch of
[fill triangulation and winding][fill].

- **Ear clipping (`mapbox-earcut`).** The algorithm Manim's OpenGL renderer uses
  (`earclip_triangulation` → `mapbox_earcut.triangulate_float32`). Fast and
  simple, but it _requires a simple polygon_ — hence the `skia-pathops`
  preprocessing above. It emits an index buffer over the flattened boundary
  vertices.
- **Lyon's `FillTessellator`.** A sweep-line tessellator (see
  [Lyon][lyon-sec]) that is more robust than ear clipping — it applies the
  [nonzero/even-odd winding rule][fill] itself during the sweep, so it tolerates
  more input than earcut, though it is still happiest with clean geometry.
- **The stencil alternative.** Stencil-and-cover ([NanoVG][nanovg-sec], Skia
  Ganesh, ManimGL) _avoids_ tessellation of the interior: it draws a raw triangle
  fan into the stencil to accumulate the [winding number][fill], then covers. It
  trades a triangulation pass for an extra framebuffer pass and is robust to
  self-intersection without boolean preprocessing — which is why ManimGL dropped
  its earcut path in favour of GPU winding fill.

### Choosing a path for a hybrid engine

| Fill strategy             | Preprocessing needed                    | Backends                          |
| ------------------------- | --------------------------------------- | --------------------------------- |
| CPU winding fill          | none                                    | Cairo, Blend2D, `tiny-skia`/resvg |
| GPU triangulation         | booleans → flatten → tessellate         | Lyon, `mapbox-earcut` + your GL   |
| GPU stencil-and-cover     | flatten only (no booleans/tessellation) | NanoVG, Skia Ganesh, ManimGL      |
| GPU compute rasterization | flatten (on-GPU); no CPU preprocessing  | Vello                             |

The CPU column is why a deterministic [oracle][cpugpu] wants a winding-fill
rasterizer: it collapses this entire preprocessing chain into a single API call.

<!-- References -->

[fill]: ../concepts.md#fill-triangulation-and-winding
[decast]: ../concepts.md#de-casteljau-evaluation
[basis]: ../concepts.md#bezier-basis-quadratic-vs-cubic
[glyph]: ../concepts.md#glyph-outline-extraction
[cpugpu]: ../concepts.md#cpu-vector-vs-gpu-vector-rendering
[ex-bezier]: ../examples/bezier-eval.d
[lyon-sec]: ./gpu-vector.md#lyon
[nanovg-sec]: ./gpu-vector.md#nanovg
[skia-gpu]: ./gpu-vector.md#skia
[pathops-repo]: https://github.com/fonttools/skia-pathops
[skpathops-h]: https://github.com/google/skia/blob/88954ef8f36d064fda7d81c3353edd06f99e7e4b/include/pathops/SkPathOps.h
[skia-repo]: https://github.com/google/skia
[mc-boolean]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/mobject/geometry/boolean_ops.py
