# Slug Library (C++ / GPU, proprietary)

Slug renders glyphs on the GPU straight from quadratic Bézier outlines — no atlas,
no signed distance field, no per-size cache — and is the reference for the
"GPU-direct-from-outline" option in RQ2.

| Field            | Value                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------- |
| Language         | C++ (library); GLSL/HLSL/MSL shaders                                                        |
| License          | Proprietary, per-engineer commercial license with source ([sluglibrary.com][site])          |
| Repository       | n/a (proprietary; no public repository)                                                     |
| Documentation    | [sluglibrary.com][site]; the algorithm paper [Lengyel, JCGT 6(2), 2017][paper] ([PDF][pdf]) |
| Category         | rasterizer                                                                                  |
| Layer(s) covered | raster · outline · (layout, above our scope)                                                |
| Pinned revision  | n/a (proprietary; no public repository) — site and paper fetched 2026-10-02                 |

## Overview

### What it solves

Text inside a 3-D scene is drawn under a transform that changes every frame, so
no atlas resolution is ever right. The paper's abstract states the whole claim:

> This paper describes a method for rendering antialiased text directly from
> glyph outline data on the GPU without the use of any precomputed texture
> images or distance fields. [...] Our method overcomes numerical precision
> problems that produced artifacts in previously published techniques and
> promotes high GPU utilization with an implementation that naturally avoids
> divergent branching.

— [Lengyel 2017, abstract][paper]

### Design philosophy

Resolution independence is bought with arithmetic rather than storage. Where SDF
and MSDF sample an "infinitely precise description of a glyph outline" into a
texture and inherit its limits, Slug keeps the control points exact and pays a
per-fragment root-counting loop. The site positions the product as "the only
existing GPU method that renders properly antialiased glyphs with no artifacts
under both magnification and minification" ([sluglibrary.com][site]).

## How it works

**Winding by ray casting, made exact.** A fragment is inside when the sum of
contour winding numbers is nonzero. For a ray along `+x` from the fragment, each
quadratic `C(t) = (1−t)²p₁ + 2t(1−t)p₂ + t²p₃` is intersected by solving
`(y₁ − 2y₂ + y₃)t² − 2(y₁ − y₂)t + y₁ = 0`. The naive `t ∈ [0, 1)` range test is
where GLyphy and Dobbie's vector textures sparkle; Slug drops it. It classifies
the curve by whether each `yᵢ > 0` — three bits, eight equivalence classes — and
reads a two-bit contribution code from a constant:

```c
/* Equation (2): shift code from the signs of the translated y-coordinates.  */
code = ((y1 > 0) ? 2 : 0) + ((y2 > 0) ? 4 : 0) + ((y3 > 0) ? 8 : 0);
bits = 0x2E74 >> code;        /* bit 0: +1 at t1 if Cx(t1) >= 0; bit 1: -1 at t2 */
```

— reconstructed from §2 of [the paper][paper] (the lookup value and Equation 2
are verbatim; the GLSL shader itself ships as supplemental `GlyphShader.glsl`)

"The shift code is an exact calculation based on the translated y-coordinates of
the input control points", so a crossing is counted for all `x ≤ x₀` and not
counted beyond — no epsilons, no perturbation, and the shared-endpoint-tangent
case cancels exactly ([§2][paper]). `b² − ac` is clamped to zero so the
no-real-root case also cancels.

**Coverage, not a bit.** Instead of an integer the shader accumulates
`f = sat(m·Cx(tᵢ) + ½)` where `m` is pixels per em — a 1-pixel linear ramp along
the ray direction. Averaging the `+x` and `+y` rays gives the shipped AA; the
paper notes more ray directions or in-pixel supersampling (sharing `a` and `b`
across samples) raises isotropy at cost ([§2, §6][paper]).

**Bands make it O(curves near the ray), not O(curves).** Each glyph is cut into
up to 16 equal-width horizontal and 16 vertical bands; per band the intersecting
curves are sorted descending by max coordinate so the loop early-outs when
`max{x₁,x₂,x₃}·m < −½`. Each band is optionally split at the curve median, with
fragments on the far side firing `−x`/`−y` rays over an ascending-sorted copy —
a divergence trade that only pays at large sizes ([§3][paper]). Geometry is one
quad per glyph (expanded by half a pixel), optionally corner-clipped to an
octagon.

**Data lives in two textures.** `curveTex` is RGBA16F: `p₁`,`p₂` in one texel,
`p₃` in the next, shared with the following curve, "slightly larger than eight
bytes per curve". `bandTex` is RGBA16UI: a header texel per band (count, offset,
split location) followed by curve-location texels carrying the positive-sort list
in RG and the negative-sort list in BA ([§4, Fig. 5][paper]). The band-data
start travels as 12-bit coordinates in `glyphParam`, capping that texture at
4096×4096.

## Analysis spine

### 1. Layering and ownership

The public product spans parser, layout and renderer — the site lists kerning,
ligatures, mark placement, OpenType feature selection and COLR/CPAL emoji — but
the paper covers only the rasterizer, and the library's ownership model is not
publicly documented. Observable facts: fonts are preprocessed offline into a
`.slug` file "containing glyph outlines, optimization data, kerning data, join
sequence data, mark attachment data, and color layer data" ([site][site]), which
the engine uploads as the two textures. Lifetime is therefore the GPU resource's;
nothing is allocated per glyph at draw time. Thread-safety: n/a in public
sources.

### 2. Face loading and table access

TrueType and CFF-flavoured OpenType are accepted by the offline tool; cubic CFF
outlines must be reduced to quadratics since the shader "restrict[s] ourselves to
the quadratic curves used by TrueType fonts" ([§2][paper]). No raw-table API is
exposed; everything is baked. Implicit on-curve points are made explicit, which
is one reason the preprocessed data is "roughly twice as large to several times
as large as the TrueType font" ([§5][paper]; Arial 894 KB → 1549 KB, JhengHei
20.6 MB → 52.8 MB in Table 3).

### 3. Shaping

Out of scope for the paper. The site claims kerning, ligature replacement,
combining-mark placement and feature substitution inside the library; API shape
is not public, so nothing here informs `sparkles:font`'s shaper design.

### 4. Variation and instances

Not addressed in any public source. Baked control points imply a variable font
would have to be instanced before preprocessing; interpolating `curveTex` on the
GPU is conceivable but undocumented.

### 5. Rasterization and outlines

This is the subject. Outline units in the shader are **em-square coordinates**
(the interpolated `texcoord`), with the pixel size entering only as `m`, so one
dataset serves every scale, rotation and perspective. AA is analytic linear
coverage along two axis rays, no hinting, no LCD, no gamma step in the paper.
COLRv0 is "an outer loop" over layers with extra colour data ([§6][paper]).
Cost: on a GTX 1060, 50 lines at 32 px/em over 2 Mpx takes 1.1 ms for Arial
(≈20 curves per capital) and 13.3 ms for Wildwood (≈546), against 26 µs for a
prerendered-atlas shader — "roughly 40 times as long" in the best case, and 4×
faster than Dobbie's method on Centaur ([Table 2, §5][paper]). Fragment work
scales with curves per band, so font complexity, not pixel count, sets the
budget.

### 6. Metrics and measurement

Not in the paper. The `.slug` file carries kerning and mark-attachment data, so
the library owns advances; which `OS/2`/`hhea` fields it uses is unpublished.

### 7. Discovery, matching and fallback

n/a. Slug consumes files handed to it; there is no system enumeration or fallback
chain.

## What it teaches `sparkles:font`

- **A sign-classification winding test is a 16-bit constant.** `0x2E74` plus
  Equation 2 is the entire robustness story; any D rasterizer (CPU or compute)
  that counts quadratic crossings should adopt it rather than range-test roots.
- **Quadratic-only is a design choice with a cost.** CFF cubics must be
  approximated offline; a from-scratch rasterizer that wants one code path for
  `glyf` and `CFF` must decide the same thing.
- **Per-glyph band lists are the atlas replacement.** Build them once per face
  at em-space resolution, not per size — the inverse of a glyph cache keyed by
  pixel size.
- **Coverage along axis rays is cheap AA, but anisotropic.** Terminal-sized text
  (10–16 px) is exactly where the paper's own optimisations stop paying.
- **Budget by curves, not pixels.** 40× a textured quad in the best case rules
  this out as a terminal's default path; it is the right tool for zoomable,
  rotated or perspective text in `hue --gui` or the font explorer.

## Strengths

- Exact, artifact-free under any affine or projective transform; one dataset per
  font regardless of size.
- Branch-free inner loop with high thread coherence; no per-size caching layer to
  invalidate.
- Sharp corners preserved — the failure mode of SDF/MSDF — see [msdfgen.md][msdfgen].

## Weaknesses

- Proprietary; API and ownership model unverifiable from public sources.
- Fragment cost is tens of times a textured quad and grows with outline
  complexity; CJK fonts bake to multi-tens-of-MB textures.
- No hinting, no LCD/subpixel, no documented variation path; quadratic-only.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                 | Trade-off                                              |
| ---------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------ |
| Winding by sign classes, not root range tests  | Exact for all finite inputs; kills sparkle/streak         | Quadratic curves only                                  |
| Bake curves + band lists into textures offline | No runtime allocation; one dataset for every size         | Data 2–several × the `.ttf`; 4096-texel address limit  |
| Two axis rays with linear coverage             | Cheap analytic AA, branch-free                            | Anisotropic; isotropy costs more rays or supersampling |
| Band split with reversed rays                  | Halves curves scanned for large glyphs                    | Divergence hurts at small sizes; made optional         |
| One quad (or octagon) per glyph                | Trivial layout; fixed vertex count independent of outline | Every covered fragment runs the curve loop             |

## Sources

- Eric Lengyel, "GPU-Centered Font Rendering Directly from Glyph Outlines",
  Journal of Computer Graphics Techniques vol. 6 no. 2, pp. 31–47, published
  2017-06-14 — [landing page][paper], [PDF][pdf]. Supplemental `GlyphShader.glsl`.
- [sluglibrary.com][site] — product description, supported formats, `.slug`
  contents, platform list, licensing (fetched 2026-10-02).
- Context: [servo/pathfinder README][pathfinder] — a tile-based GPU rasterizer
claiming "exact fractional trapezoidal area coverage on a per-pixel basis";
Loop & Blinn 2005 as cited by the paper.
<!-- References -->

[site]: https://sluglibrary.com/
[paper]: http://jcgt.org/published/0006/02/02/
[pdf]: https://jcgt.org/published/0006/02/02/paper.pdf
[pathfinder]: https://github.com/servo/pathfinder
[msdfgen]: ./msdfgen.md
