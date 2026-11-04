# GPU rendering for animated font previews

**Last reviewed:** November 4, 2026

For `text-lab` on the Xiaomi 11T Pro, use a hybrid: retain the existing hinted
mask atlas for stable UI; evaluate banded GPU coverage for continuously changing
preview glyphs. A full compute renderer is a later option if profiling identifies
CPU curve preparation as the remaining limit. This is an architectural inference
from the sources below, not an Adreno benchmark result.

The workload changes variable-font coordinates every frame and targets 120 Hz
(8.33 ms per frame). Session measurements report fixed-font CPU p99 of
5.09–7.02 ms, sustained weight-animation CPU p95 of 8.03–15.40 ms with four
raster workers, and an initial direct-coverage experiment at CPU p95 11.09 ms /
GPU p95 3.44 ms. These runs have different conditions and are not an A/B result;
none establishes sustained 120 Hz. Moving coverage to the GPU has yet to remove
enough CPU work.

## What the state of the art offers

There is no universal winning GPU text algorithm. The surveyed implementations
optimize different reuse patterns; their names alone do not identify where
rasterization happens.

| Family                            | Actual work distribution                                                                                                                | Consequence for changing axes                                                                                                                                                                               |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Slug][slug-note]                 | Fragment shader intersects original quadratics; sorted horizontal/vertical bands restrict curve traversal.                              | Avoids per-size bitmap generation, but changed outlines require updated geometry and valid band membership/order. The paper does not measure per-frame variable-font preparation. [Paper §§2–4][slug-paper] |
| [Vello compute][vello-note]       | CPU resolves glyph outlines; GPU flattens, bins, computes backdrops, tiles and evaluates coverage through multiple dispatches.          | Offloads substantially more geometry work, at the cost of intermediate buffers, allocation management and synchronization. [Render pipeline][vello-render]                                                  |
| [Vello Sparse Strips][vello-note] | CPU flattens and bins paths into sparse horizontal strips; GPU vertex/fragment stages rasterize/composite the scheduled representation. | Reduces downstream work around empty/full regions, but retains CPU geometry preparation. It is a different architecture from compute Vello. [Architecture][vello-arch]                                      |
| [Skia][skia-note]                 | Chooses direct masks, distance-field text, paths and drawable glyphs; cache/strike preparation remains part of the text pipeline.       | A practical hybrid precedent; a GPU backend does not imply GPU variation evaluation or hinting. [Subrun selection][skia-subruns]                                                                            |
| [glyphon][glyphon-note]           | Calls the CPU rasterizer on misses, uploads glyph images and draws atlas instances.                                                     | Excellent reuse for stable text; continuous new instances still pay rasterization/upload. [Preparation][glyphon-render]                                                                                     |
| [MSDF][msdf-note]                 | Generates a distance-field texture, reconstructs coverage cheaply in a fragment shader.                                                 | New outlines require new fields; generation and quality control become per-instance work. [Generator][msdf-generator], [shader contract][msdf-readme]                                                       |

Vello's pinned architecture explicitly calls the compute renderer
“experimental”; its primary renderer family is Sparse Strips. That is evidence
for comparing both designs, not proof that compute is slower on this device.
[Vello architecture][vello-arch]

## Where the current experiment differs

The working-tree experiment's `coverage_fragment.d` loops over every uploaded
flattened edge for every covered pixel. A shared geometry texture reduces
resource setup; it does not reduce edge tests or CPU flattening. This is an
unbanded line-area rasterizer, rather than Slug's direct-curve algorithm.

Slug's relevant contribution is spatial acceleration plus robust quadratic
crossing classification. Its two-axis coverage ramps are not exact box-filter
area integration. Keeping curves can avoid CPU flattening, but cubic outlines
need a separate treatment and hinted outlines still depend on size/instance.
The paper's desktop timings do not predict mobile sustained performance.
[Slug §§2–6][slug-paper]

For the current signed-area method, start with horizontal bands containing every
edge that can affect the **whole pixel footprint**, including the union fallback's
subpixels. A center-ray band selection is insufficient. If adding x-local tiles,
carry the winding/area backdrop from edges outside the tile; simply removing
those edges changes filled interiors. Vello's [`backdrop`][vello-backdrop] and
[`coarse`][vello-coarse] stages illustrate why tile-local edges require additional
state. This is a proposed adaptation, not an algorithm claimed by Slug.

Overlap handling is a separate correctness problem. Vello documents that
integrating winding number can produce “conflation artifacts” outside winding
0/1. The experimental `CoverageAccumulator` uses a 4×4 approximation
for flagged union coverage; more samples or direct curves do not automatically
prove equivalence to the CPU oracle. [Vello `AaConfig::Area`][vello-aa]

## Recommended architecture and decision gates

1. **Keep one shaping and hinting contract.** Feed preview rasterization the same
   instance, hinted geometry and placement as the CPU path. Cover all declared
   axes, including custom axes; normalize through the font's mapping. Variation
   can change substitutions, positioning, metrics and hinting data, so geometry
   interpolation alone cannot replace the font pipeline. [OpenType variations][otvar]
2. **Batch visible instance geometry once per frame slot.** Deduplicate repeated
   glyphs at the same instance/size/hinting settings; retain stable UI masks.
   Add bands before a new renderer family. Measure decomposition, hinting,
   flattening, band construction, copying, submission and GPU coverage separately.
   Reject edge-count truncation: overflow uses the complete CPU path.
3. **Compare three bounded experiments.** Banded flattened edges isolate traversal
   savings; banded original curves test flattening removal; a glyph-only compute
   path tests GPU flatten/bin/raster. Full scene compositing is unnecessary for
   this decision. Sparse Strips is a useful CPU/SIMD alternative if its preparation
   is cheaper than current flattening, rather than an automatic CPU offload.
4. **Consider transient GPU masks when repetition pays.** Rasterize each changed
   visible glyph once into a frame-local mask, then reuse ordinary atlas draws.
   This avoids repeating curve evaluation per occurrence, but adds a pass,
   synchronization and mask storage. Compare against direct coverage on the phone.
5. **Gate promotion on quality and sustained presentation.** Compare identical
   hinted inputs at small text sizes, fractional positions, extrema, custom-axis
   combinations, overlapping/self-intersecting contours and complex/cubic glyphs.
   Check temporal stability and blending as well as image error. Measure CPU/GPU
   tails, missed presentations, memory and thermal steady state; separately timed
   percentiles neither add into a frame latency nor prove the deadline.

Changing coordinates invalidates instance geometry, bands and raster products;
unchanged glyph topology does not guarantee unchanged bounds or sorted lists.
Hinted geometry also keys on size and hinting policy. Vello partitions its caches
by normalized coordinates and constructs hinting instances for the selected
location, demonstrating that a vector cache does not erase instance invalidation.
[Glyph preparation][vello-glyph]

Distance fields remain appropriate for reusable, transformed labels and effects.
They are a weak first choice here: field generation, edge coloring and error
correction must amortize over reuse, and reconstruction is a different quality
contract from hinted pixel coverage. Preserve the exact-size CPU fallback for
small text and unsupported cases; do not silently substitute scaled cached masks.
[MSDF generation][msdf-generator], [error correction][msdf-correction],
[reconstruction][msdf-readme]

## Sources and further reading

- [Existing rasterization comparison][comparison] and [shared terminology][concepts].
- [Lengyel's original paper][slug-paper], rather than product quality claims.
- [Vello architecture][vello-arch], [compute dispatches][vello-render] and
  [coverage limitations][vello-aa].
- [Skia text strategy selection][skia-subruns], [glyphon preparation][glyphon-render]
  and [MSDF shader contract][msdf-readme].

<!-- References -->

[slug-note]: ./slug.md
[vello-note]: ./vello.md
[skia-note]: ./skia.md
[glyphon-note]: ./glyphon.md
[msdf-note]: ./msdfgen.md
[comparison]: ./comparison.md#rq2-rasterization-and-gpu
[concepts]: ./concepts.md
[slug-paper]: https://jcgt.org/published/0006/02/02/paper.pdf
[vello-arch]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/ARCHITECTURE.md
[vello-render]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_research/src/render.rs
[vello-backdrop]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_shaders/shader/backdrop.wgsl
[vello-coarse]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_shaders/shader/coarse.wgsl
[vello-aa]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_research/src/lib.rs
[vello-glyph]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/glifo/src/glyph.rs
[skia-subruns]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/text/gpu/SubRunContainer.cpp
[glyphon-render]: https://github.com/grovesNL/glyphon/blob/49dc8f7bafa8091f4d71521fd62ee6f647b556f5/src/text_render.rs
[msdf-readme]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/README.md
[msdf-generator]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/msdfgen.cpp
[msdf-correction]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/MSDFErrorCorrection.h
[otvar]: https://learn.microsoft.com/en-us/typography/opentype/spec/otvaroverview
