# Images: formats, pixel models and algorithms

A primary-source catalog for `sparkles:{image,video}`: how other ecosystems model
pixels and views, decode and encode image formats safely, run image algorithms on
SIMD and GPU compute, and move bytes from storage to the GPU. It exists to inform a
design decision that is **not yet made**: whether the library is one package or splits
into image-core, image-formats and image-algorithms. That decision follows the research
and a round of experiments, not this page.

> [!IMPORTANT]
> This tree is under construction. Wave 0 delivered the Sparkles [baseline](#sparkles-baseline)
> (what the repository already has or has specified) and the [papers](#papers). The
> subject deep-dives, the shared concepts and the comparison arrive in later waves; this
> page lists them as planned rather than linking to files that do not exist yet.

**Last reviewed:** October 28, 2026

## Questions this survey answers

1. **Pixel and memory model.** Which representation of planes, strides, tiles, views
   and N-D extents serves both a viewer and a scientific pipeline, and does mir's
   `Slice` fit?
2. **Generic interfaces in D.** Which mechanism (concepts, traits, type classes,
   design by introspection) carries pixel and image abstractions, and which
   cross-language ideas transfer?
3. **Generic algorithms that stay fast.** Lazy ranges, algorithm/schedule separation,
   SIMD dispatch and GPU kernels: how do they compose?
4. **Codec architecture.** What gives incremental, suspendable, hostile-input-safe
   decoding (Wuffs), and what must the `sparkles:wired` binary description format
   express?
5. **Colour, HDR and metadata.** ICC, CICP, gain maps, EXIF and XMP: what is the
   minimum model?
6. **File to GPU.** How do `sparkles:event-horizon`, io_uring/IoRing, Vulkan upload,
   GPU decompression and GPU texture formats fit together?
7. **SIMD versus GPU compute.** Where is the break-even, and what is shared between
   the two kernel forms?
8. **Correctness.** Oracles, conformance corpora, fuzzing and differential testing.
9. **Package boundaries.** Evidence for or against a split into image-core, formats
   and algorithms.

## Sparkles baseline

What the repository ships, specifies, drafts and plans in each area the image work
touches. Every doc separates those four statuses, ends with gaps tagged by the
questions above, and lists the open decisions for the design review.

| Area                                | Covers                                                                                 | Link                    |
| ----------------------------------- | -------------------------------------------------------------------------------------- | ----------------------- |
| `sparkles:wired` and Flat           | what binary description can express today versus what image headers and codecs need    | [Baseline][bl-wired]    |
| `sparkles:event-horizon`            | io_uring ops, offload pools, fibers; the file-to-GPU seam; I/O-bound and CPU-bound use | [Baseline][bl-eh]       |
| `sparkles:vulkan` and `ui-vulkan`   | bound commands and extensions, memory sub-allocator, the one upload path               | [Baseline][bl-vk]       |
| `sparkles:shaders`, math, host SIMD | graphics-only shaders, compute milestones, SIMD precedents and dispatch                | [Baseline][bl-shaders]  |
| Existing image code and consumers   | the two PNG decoders, alpha conventions, terminal images, oracles, explorer template   | [Baseline][bl-existing] |

## Planned contents

Not yet written; each is delivered in a later wave.

- Shared `concepts.md`, a master catalog of about a hundred subjects in three depth
  tiers, taxonomy tables and a milestone timeline.
- Deep-dives by cluster: D landscape (mir, dcv, color, gamut), generic image
  libraries, GPU and SIMD, image formats, colour, safety (Wuffs), and storage-to-GPU I/O.
- `papers/<thread>.md`: seven themed annotated bibliographies.
- `wired-flat-fit.md` and `wired-requirements.md`: the binary-description experiment
  and the non-binding requirements it yields for wired.
- `comparison.md`: the capstone, with a delta table against the baseline.

## Sources

- The five baseline documents above, which cite the specifications and source files
  they were read from.

<!-- References -->

[bl-wired]: ./baseline/wired.md
[bl-eh]: ./baseline/event-horizon.md
[bl-vk]: ./baseline/vulkan.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-existing]: ./baseline/existing-code.md
