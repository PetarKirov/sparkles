# Manim's scene graph: `Mobject`, `VMobject`, and the cubic-Bézier basis

How Manim Community models a drawable: a one-directional tree of `Mobject`
nodes, each carrying a flat `points` array that a `VMobject` interprets as
**cubic** Bézier curves — and why "cubic vs quadratic" is the single most
load-bearing geometry decision in the codebase. This is the object-model
companion to the Manim Community deep-dive; shared terms live in
[`../concepts.md`][concepts].

---

## How it works

### `Mobject`: a node with points and children

`Mobject` ([`mobject.py:72`][mobject]) — _"Mathematical Object: base class for
objects that can be displayed on screen"_ — is the universal node. Its `__init__`
([`mobject.py:107`][mobject]) sets a handful of fields and calls three template
hooks:

```python
# mobject.py:107 — the base Mobject constructor
def __init__(self, color=WHITE, name=None, dim=3, target=None, z_index=0):
    ...
    self.submobjects: list[Mobject] = []      # children (no parent back-ref)
    self.updaters: list[_Updater] = []
    self.color = ManimColor.parse(color)
    self.reset_points()                       # → self.points = np.zeros((0, self.dim))
    self.generate_points()                    # empty hook; subclasses build geometry
    self.init_colors()                        # empty hook; subclasses set rgba arrays
```

`reset_points` ([`mobject.py:456`][mobject]) initializes `points` to an empty
`(0, dim)` array; `generate_points` ([`mobject.py:468`][mobject]) and
`init_colors` ([`mobject.py:461`][mobject]) are deliberately empty — a subclass
like `Circle` or `Square` overrides `generate_points` to fill the array. Two
fields make the whole model: **`points`** (the geometry) and **`submobjects`**
(the children). This is [retained mode][retained]: the objects persist across
frames and animations mutate them in place.

### The family tree is one-directional

`add` ([`mobject.py:475`][mobject]) only appends to the child list —
`self.submobjects = list_update(self.submobjects, unique_mobjects)`
([`mobject.py:560`][mobject]) — and stores **no parent pointer**. Consequently
the transitive closure (the "family") is _computed_, not stored, by `get_family`
([`mobject.py:2518`][mobject]):

```python
# mobject.py:2548 — family = self + recursively flattened children, de-duplicated
sub_families = [x.get_family() for x in self.submobjects]
all_mobjects = [self] + list(it.chain(*sub_families))
return remove_list_redundancies(all_mobjects)
```

`family_members_with_points` ([`mobject.py:2552`][mobject]) filters that to nodes
with `get_num_points() > 0` — the set the renderer actually draws and the set
`Transform` zips over. The free function `extract_mobject_family_members`
([`family.py:12`][family]) does the same across a list of roots, optionally
`z_index`-sorted. Because there are no back-references, a node can be added to at
most one displayed tree at a time, and duplicate-add is a no-op with a warning
([`mobject.py:554`][mobject]).

### `__init_subclass__` wires per-type animation overrides

Every `Mobject` subclass runs `__init_subclass__` ([`mobject.py:100`][mobject]),
which resets `cls.animation_overrides = {}`, calls
`_add_intrinsic_animation_overrides()`, and snapshots `cls._original__init__`.
That is the machinery behind `mob.animate.shift(...)` and `@override_animate`:
`animation_override_for` ([`mobject.py:186`][mobject]) looks up a type-specific
animation, so a subclass can replace how it is transformed without touching the
`Animation` classes.

---

## `VMobject` and vector geometry

A drawable shape is a `VMobject` ([`vectorized_mobject.py:81`][vmob]) — a
`Mobject` whose `points` array encodes Bézier curves. On the default Cairo
backend it is **cubic**: `n_points_per_cubic_curve = 4`
([`vectorized_mobject.py:129`][vmob], an `__init__` default), so `points` is a
flat run of `[anchor, handle, handle, anchor, anchor, handle, handle,
anchor, ...]`. `set_anchors_and_handles` ([`vectorized_mobject.py:841`][vmob])
shows the interleaved storage directly:

```python
# vectorized_mobject.py:842 — four control arrays interleaved into one points array
nppcc = self.n_points_per_cubic_curve  # 4
arrays = [anchors1, handles1, handles2, anchors2]
for index, array in enumerate(arrays):
    self.points[index::nppcc] = array         # points[0::4]=A0, [1::4]=H1, [2::4]=H2, [3::4]=A1
```

and `gen_cubic_bezier_tuples_from_points` ([`vectorized_mobject.py:1305`][vmob])
recovers the curves by _"take every nppcc element"_ — `points[i:i+4]` for `i` in
`range(0, len, 4)`. Curves are built by `add_cubic_bezier_curve_to`
([`vectorized_mobject.py:927`][vmob]) (append `[handle1, handle2, anchor]`),
`add_line_to`, and `set_points_as_corners` ([`vectorized_mobject.py:1110`][vmob]),
which places handles _on_ the segment so the cubic degenerates to a straight
line:

```python
# vectorized_mobject.py:1152 — corners: handles interpolated along each edge
self.set_anchors_and_handles(
    *(interpolate(points[:-1], points[1:], t) for t in self._bezier_t_values))
```

### Fill and stroke are separate RGBA arrays

Color is not one attribute but several parallel arrays. `set_fill`
([`vectorized_mobject.py:282`][vmob]) writes `fill_rgbas`
([`vectorized_mobject.py:327`][vmob]); `set_stroke`
([`vectorized_mobject.py:332`][vmob]) writes `stroke_rgbas` **or**
`background_stroke_rgbas` ([`vectorized_mobject.py:344`][vmob]) depending on the
`background` flag. `interpolate_color` ([`vectorized_mobject.py:1894`][vmob])
lerps all of them independently — `fill_rgbas`, `stroke_rgbas`,
`background_stroke_rgbas`, `stroke_width`, `background_stroke_width`,
`sheen_direction`, `sheen_factor` — which is why a morph can cross-fade fill and
stroke on different schedules. Cairo consumes them as
**stroke(background) → fill → stroke** (`display_vectorized`,
[`camera.py:677`][camera]).

### Point-count alignment before interpolation

`Mobject.interpolate` ([`mobject.py:3080`][mobject]) is a straight lerp —
`self.points = path_func(mobject1.points, mobject2.points, alpha)` followed by
`interpolate_color` ([`mobject.py:3149`][mobject]) — and it _requires equal
point counts_. `VMobject.align_points` ([`vectorized_mobject.py:1747`][vmob])
makes that true: it first `align_rgbas` (stretch the color arrays to equal
length, [`vectorized_mobject.py:1875`][vmob]), then subdivides curves and inserts
null subpaths so both objects have matching subpath structure. `Transform.begin`
([`transform.py:200`][transform]) calls this via `align_data` before the first
frame; `pointwise_become_partial` ([`vectorized_mobject.py:1918`][vmob]) is the
related operation that carves a `[a,b]` sub-span out of a spline (used by
`Create`/`ShowPartial`), splitting inner cubics with `partial_bezier_points` and
`integer_interpolate` ([`vectorized_mobject.py:1972`][vmob]). See
[`../concepts.md`][align] and the [`affine-transform.d`][ex-affine] probe for the
coordinate-space math.

---

## Bézier basis: cubic vs quadratic

This is the crux. Manim ships **two** `VMobject` lineages with **different Bézier
degrees**, selected by the `ConvertToOpenGL` metaclass
([`opengl_compatibility.py:17`][ogl-compat]) — _"Metaclass for swapping
(V)Mobject with its OpenGL counterpart at runtime depending on config.renderer"_:

| Backend         | Class            | Points/curve                                    | Basis         | Fill                            |
| --------------- | ---------------- | ----------------------------------------------- | ------------- | ------------------------------- |
| Cairo (default) | `VMobject`       | `n_points_per_cubic_curve = 4` ([`:129`][vmob]) | **cubic**     | Cairo `fill_preserve` (winding) |
| OpenGL          | `OpenGLVMobject` | `n_points_per_curve = 3` ([`:112`][ogl-vmob])   | **quadratic** | GPU earcut triangulation        |

When `config.renderer == RendererType.OPENGL`, the metaclass rewrites base
classes through `{"Mobject": OpenGLMobject, "VMobject": OpenGLVMobject}`
([`opengl_compatibility.py:31`][ogl-compat]), so `class Dot(VMobject)` silently
inherits the quadratic lineage with its `quadratic_bezier_fill` /
`quadratic_bezier_stroke` shaders ([`opengl_vectorized_mobject.py:84`][ogl-vmob]).

### The conversion is asymmetric

A quadratic elevates to a cubic **exactly**; a cubic lowers to quadratics
**lossily**. Manim's own code encodes both directions.

**Quadratic → cubic (exact).** The cubic `VMobject` accepts a quadratic and
degree-elevates it, with an unusually candid comment:

```python
# vectorized_mobject.py:978 — add_quadratic_bezier_curve_to elevates to a cubic
# 2. Place the 2 middle control points 2/3 along the line segments
#    from the end points to the quadratic curve's middle control point.
# I think that's beautiful.
self.add_cubic_bezier_curve_to(
    2 / 3 * handle + 1 / 3 * self.get_last_point(),
    2 / 3 * handle + 1 / 3 * anchor,
    anchor,
)
```

That `2/3`-rule is the same exact elevation the SVG importer uses
(`handle_commands` for `n_points_per_curve == 4`,
[`svg_mobject.py:586`][svg-mob]: `add_quad → add_cubic(start, (start+2cp)/3,
(2cp+end)/3, end)`), and it is exactly what the [`bezier-eval.d`][ex-bezier]
probe reproduces — printing a max sample deviation of `0` within floating-point
epsilon, confirming quadratics are a strict subset of cubics.

**Cubic → quadratic (lossy).** The OpenGL lineage cannot store a cubic, so
`OpenGLVMobject.add_cubic_bezier_curve_to` ([`opengl_vectorized_mobject.py:496`][ogl-vmob])
calls `get_quadratic_approximation_of_cubic(...)` and stores **two** quadratics
per cubic ([`opengl_vectorized_mobject.py:499`][ogl-vmob]). The SVG importer does
the same on the quadratic path ([`svg_mobject.py:602`][svg-mob]). A single
quadratic cannot follow a cubic's inflection; the [`bezier-eval.d`][ex-bezier]
probe fits the best single quadratic to an inflected cubic and prints the
residual error — the per-curve cost the quadratic backends pay, split across two
quads to keep it small. See [`../concepts.md`][basis].

> [!NOTE]
> The upstream authors have long wanted to unify on the cubic layout — the
> module's TODO opens with _"Change cubic curve groups to have 4 points instead
> of 3"_ ([`vectorized_mobject.py:73`][vmob]). It has not happened: the Cairo
> path is cubic and the OpenGL path is quadratic in the reviewed tree.

---

## Coordinate space

Every geometric operation is an [affine map][affine] on the flat `points` array.
`Mobject` methods like `shift`, `scale`, `rotate`, and `apply_matrix` transform
`points` in world space; the camera then applies one more affine — the
world-to-pixel matrix — when rasterizing (`ctx.set_matrix(cairo.Matrix(pw/fw, 0,
0, -(ph/fh), ...))`, [`camera.py:591`][camera]). Because composing affine maps is
matrix multiplication (right-to-left function composition), a chain of
transforms collapses to a single matrix; the [`affine-transform.d`][ex-affine]
probe proves the composed matrix and the sequential application agree to
floating-point epsilon, and that translate·scale ≠ scale·translate.

---

## Sources

- [`manim/mobject/mobject.py`][mobject] — `Mobject`, `add`/`get_family`,
  `__init_subclass__`, `interpolate`, `align_data`.
- [`manim/mobject/types/vectorized_mobject.py`][vmob] — cubic `VMobject`,
  interleaved `points` layout, fill/stroke arrays, `align_points`,
  `pointwise_become_partial`, the quadratic→cubic elevation.
- [`manim/mobject/opengl/opengl_vectorized_mobject.py`][ogl-vmob] ·
  [`opengl_compatibility.py`][ogl-compat] — the quadratic OpenGL lineage and the
  metaclass swap.
- [`manim/mobject/svg/svg_mobject.py`][svg-mob] — `handle_commands`, both
  elevation (cubic) and lowering (quadratic) code paths.
- [`manim/camera/camera.py`][camera] — how the cubic tuples reach Cairo.
- [`manim/utils/family.py`][family] · [`manim/animation/transform.py`][transform]
  — family extraction and the align-then-lerp morph.

Related: the Manim Community deep-dive · [`../concepts.md`][concepts] ·
[`text-pipeline.md`][text-pipeline] · [`caching.md`][caching] ·
[`manimgl`][manimgl]. Probes: [`bezier-eval.d`][ex-bezier] ·
[`affine-transform.d`][ex-affine].

<!-- References -->

[text-pipeline]: ./text-pipeline.md
[caching]: ./caching.md
[concepts]: ../concepts.md
[manimgl]: ../manimgl.md
[retained]: ../concepts.md#retained-vs-immediate-mode
[basis]: ../concepts.md#bezier-basis-quadratic-vs-cubic
[align]: ../concepts.md#transform-and-point-count-alignment
[affine]: ../concepts.md#affine-transform-and-coordinate-space
[ex-bezier]: ../examples/bezier-eval.d
[ex-affine]: ../examples/affine-transform.d
[mobject]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/mobject.py
[vmob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/types/vectorized_mobject.py
[ogl-vmob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/opengl/opengl_vectorized_mobject.py
[ogl-compat]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/opengl/opengl_compatibility.py
[svg-mob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/svg/svg_mobject.py
[camera]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/camera/camera.py
[family]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/family.py
[transform]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/animation/transform.py
