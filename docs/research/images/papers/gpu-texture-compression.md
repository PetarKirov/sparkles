# Papers: GPU texture compression and supercompression

Fixed-rate block formats (`BCn`, `ETC`, `ASTC`, `PVRTC`) are what the GPU samples;
supercompression (`RDO`, `BasisLZ`, `UASTC`, `GST`) and neural codecs decide what
ships, and `KTX2` with the Khronos Data Format Specification is the container that
carries both. A second line of work — normals, alpha, light maps — shows that what a
texel _means_ should drive the format and the encoder's error metric.

| Field             | Value                                                                                                                                                                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Thread**        | `gpu-texture-compression`                                                                                                                                                                                                              |
| **Scope**         | GPU texture compression and supercompression: `BCn`, `ETC1`/`ETC2`, `ASTC`, `PVRTC`, `UASTC`/Basis, `RDO`, `KTX2`, neural texture compression, HDR (`BC6H`), semantic-specific formats (normals, alpha, light maps), GPU-side encoding |
| **Entries**       | 26 (22 with a local PDF, 4 web specifications or write-ups)                                                                                                                                                                            |
| **Last reviewed** | October 28, 2026                                                                                                                                                                                                                       |

> [!NOTE]
> Quote page numbers ("p. N") are PDF page indices of the local copy, counted from
> the first page of the file, not printed folios. Quotes from web-only sources cite
> the page itself.

## Why this thread matters to sparkles

`sparkles:image` will hold pixels in two very different shapes: _sample planes_
(decoded RGBA/YUV/float rasters that generic algorithms iterate over) and _block
planes_ (opaque 64- or 128-bit tiles that only a GPU sampler, a transcoder or a
software decoder understands). The generic image abstraction therefore needs a
block-format axis (block footprint, bytes per block, colour model, transfer
function, signedness, HDR) instead of assuming per-texel addressability, and the
[Khronos Data Format Specification][kdfs] already names that axis. Codec
architecture splits into three layers — fixed-rate block codecs, a lossless or
RDO supercompression layer, and the `KTX2` container — each with different
hostile-input exposure: block decoders must be total over every bit pattern
(reserved `BC6H` modes, invalid `ETC` deltas, implementation-defined `BC4`
comparisons), while the supercompression layer parses variable-length Huffman,
ANS or Zstandard streams and must enforce size budgets. Encoders are a SIMD
problem (van Waveren's `MMX`/`SSE2` `DXT` encoder, QuickETC2's `AVX2`) and,
since 2006, a GPU problem too; transcoders and neural decoders are a GPU-compute
problem (`sparkles:shaders`, `sparkles:vulkan`), and the per-mip independence of
`KTX2` supercompression is what makes an `event-horizon` `io_uring` →
staging-buffer → `vkCmdCopyBufferToImage` streaming path possible without
inflating whole files. Colour and semantics matter too: sRGB versus linear block
formats, `BC6H`'s half-float range, YCoCg tricks inside `DXT5`, and normal maps
whose third component is rebuilt in the shader all change what "the same pixel"
means — and which error metric an encoder should minimise.

## Annotated bibliography

### Iourcha, Nayak, Hong — US 5,956,431 (`S3TC` / `DXT1`)

| Field        | Value                                                                                           |
| ------------ | ----------------------------------------------------------------------------------------------- |
| Authors      | Konstantine I. Iourcha, Krishna S. Nayak, Zhou Hong (assignee: S3 Incorporated)                 |
| Venue/Year   | US patent 5,956,431, filed October 2, 1997, granted September 21, 1999                          |
| DOI or arXiv | none (patent); [Google Patents record][us5956431]                                               |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/iourcha1999-us5956431-s3tc-patent.pdf` |
| Open access  | Y (public patent document)                                                                      |

**Claim.** An image is cut into fixed-size blocks; each block stores two
reference colours ("codewords") plus a per-pixel index into a small palette in
which the remaining colours are _inferred_ by interpolation between the
codewords. Because every block has the same number of bits, any block — and so
any texel — can be addressed directly, which is the random-access property all
later GPU formats keep.

**Verbatim quote** (p. 1, abstract; OCR capitalisation preserved):

> the color quantizer Selects Some number of base points, or codewords, that Serve as reference pixel values, Such as colors, from which quantized pixel values are derived.

**Relevance to sparkles.** This is the `BC1` block (two `RGB565` endpoints,
2-bit indices, 64 bits per 4×4). It fixes the shape of the simplest
`sparkles:image` block decoder: a pure, `@nogc nothrow` function from
`ubyte[8]` to a 4×4 tile, with the endpoint-ordering trick (`c0 <= c1` selects
the three-colour + transparent mode) handled explicitly. The same block layout is
reused inside `BC2`/`BC3` and as the colour half of `DXT5`-based YCoCg.

**Caveats.** A patent, not a peer-reviewed paper; the OCR text is noisy. The
`S3TC` patent family expired around 2017–2018, which is why Mesa and others now
ship `S3TC` by default; check continuations (`US 6,658,146`, `US 7,039,244`) before
asserting freedom to operate in any jurisdiction.

### Fenney — Texture compression using low-frequency signal modulation (`PVRTC`)

| Field        | Value                                                                                                    |
| ------------ | -------------------------------------------------------------------------------------------------------- |
| Authors      | Simon Fenney (Imagination Technologies)                                                                  |
| Venue/Year   | Graphics Hardware 2003, pp. 84–91                                                                        |
| DOI or arXiv | [10.2312/EGGH03/084-091][fenney2003]                                                                     |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/fenney2003-low-frequency-signal-modulation.pdf` |
| Open access  | Y (Eurographics Digital Library)                                                                         |

**Claim.** Instead of independent blocks, `PVRTC` stores two low-resolution
images that are bilinearly upscaled and blended per texel by a 1- or 2-bit
modulation signal, giving 4 bpp and 2 bpp modes without visible block seams. It
remains fixed-rate and needs no indirection, unlike VQ schemes.

**Verbatim quote** (p. 1, abstract):

> It uses a representation that is based on the blending of two (or more) ‘low frequency’ signals using a high frequency but low precision modulation signal.

**Relevance to sparkles.** `PVRTC` is the counter-example to "a block decodes in
isolation": decoding one texel needs the neighbouring blocks' colour data, so a
`sparkles:image` block-plane abstraction must expose a neighbourhood (or whole
image) decode path, not only `decodeBlock(in ubyte[N])`. It also shows why
encoders for such formats are global optimisation problems and hard to
parallelise per block.

**Caveats.** `PVRTC` is effectively legacy (PowerVR-specific; Vulkan exposes it
only through the deprecated `VK_IMG_format_pvrtc` extension).
Imagination patents may still apply to `PVRTC2`. Worth a software decoder for
legacy assets, not an encoder.

### Ström, Akenine-Möller — iPACKMAN (`ETC1`)

| Field        | Value                                                                            |
| ------------ | -------------------------------------------------------------------------------- |
| Authors      | Jacob Ström, Tomas Akenine-Möller                                                |
| Venue/Year   | Graphics Hardware 2005, pp. 63–70                                                |
| DOI or arXiv | [10.2312/EGGH/EGGH05/063-070][strom2005] (also ACM `10.1145/1071866.1071877`)    |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/strom2005-ipackman.pdf` |
| Open access  | Y (author copy via `web.archive.org` snapshot of the Lund graphics group page)   |

**Claim.** iPACKMAN, standardised as Ericsson Texture Compression (`ETC1`),
splits a 4×4 block into two 2×4 or 4×2 halves, each with one base chrominance
and a luminance-modifier table; pixels pick a modifier, exploiting the eye's
lower chroma sensitivity. A differential mode codes the second base colour as a
delta from the first, buying precision at the same 4 bpp.

**Verbatim quote** (p. 1):

> iPACKMAN compresses to a rate of 4 bits per pixel (bpp).

**Relevance to sparkles.** `ETC1` is the mandatory format of OpenGL ES 2 era
Android and the base layer of `ETC2`, `EAC` and Basis `ETC1S`. A D decoder is
small and table-driven; the modifier tables belong in `static immutable` data
and the decoder can be exercised exhaustively over table indices at compile time
(`@ctfe` tests).

**Caveats.** 2005 hardware assumptions; `ETC1` has no alpha. Licensing terms
for `ETC1`/`ETC2` outside Khronos APIs were not checked for this entry.

### Ström, Pettersson — `ETC2`: texture compression using invalid combinations

| Field        | Value                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------- |
| Authors      | Jacob Ström, Martin Pettersson                                                                    |
| Venue/Year   | Graphics Hardware 2007, pp. 49–54                                                                 |
| DOI or arXiv | [10.2312/EGGH/EGGH07/049-054][strom2007]                                                          |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/strom2007-etc2-invalid-combinations.pdf` |
| Open access  | Y (Eurographics Digital Library)                                                                  |

**Claim.** In `ETC1`'s differential mode some base-plus-delta combinations
overflow the 5-bit range and are therefore invalid; `ETC2` reinterprets those
bit patterns as three new modes (`T`, `H`, planar) without changing the bit rate
or breaking `ETC1` decoders on valid data. The paper reports about 1 dB PSNR over
`ETC1` and 0.8 dB over `S3TC`.

**Verbatim quote** (p. 1, abstract):

> Due to the use of invalid bit combinations, the system, called ETC2, is backwards compatible with iPACKMAN/ETC.

A second quote (p. 2) shows exactly which overflow creates the escape:

> Here R0 is a five bit number between [0, 31] and dR is a three bit number between [−4, 3]. But R1 should also be between [0, 31]

**Relevance to sparkles.** Mode selection by arithmetic overflow is a parser
hazard: the decoder must compute `R0 + dR` in a wider type and branch on the
out-of-range result, never wrap. This is exactly the kind of rule a `wired`-style
declarative block description cannot express as a fixed bit layout; the
`ETC2` decoder should be hand-written, with exhaustive tests over all 8-bit
`(R0, dR)` pairs.

**Caveats.** PSNR-only evaluation on a small 2007 test set. `ETC2` is mandatory
in OpenGL ES 3.0 and Vulkan's `textureCompressionETC2` feature, but desktop GPUs
often emulate it in drivers.

### van Waveren — Real-Time DXT Compression

| Field        | Value                                                                                                  |
| ------------ | ------------------------------------------------------------------------------------------------------ |
| Authors      | J.M.P. van Waveren (id Software)                                                                       |
| Venue/Year   | White paper, May 20, 2006 (published via Intel Software Network)                                       |
| DOI or arXiv | none; [archived PDF][vanwaveren2006]                                                                   |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/vanwaveren2006-real-time-dxt-compression.pdf` |
| Open access  | Y (archived copy of the author's site)                                                                 |

**Claim.** A `DXT1`/`DXT5` encoder that picks endpoints from the bounding box of
the block's colours (inset slightly) and assigns indices with branch-free
arithmetic can run in real time with `MMX`/`SSE2`, trading a little quality for
speed: on a 2.8 GHz Xeon its `SSE2` path compresses about 112 megapixels per
second to `DXT1`, against 0.17–5.46 for the four reference libraries
benchmarked. The use case is run-time compression of
procedural or transcoded textures.

**Verbatim quote** (p. 1, abstract):

> However, at the cost of a little quality a DXT compressor can be optimized to achieve real-time performance.

**Relevance to sparkles.** The template for a `sparkles:image` "fast" encoder
tier: bounding-box endpoints, integer distance computations, 16 pixels in a
handful of 128-bit registers. In D this maps onto `core.simd`/LDC vector
intrinsics with a scalar reference implementation as the test oracle; the same
structure ports to a compute shader for GPU-side encoding of render targets.

**Caveats.** x86-specific intrinsics from 2006; quality is well below
cluster-fit or `bc7enc`-class encoders. Not peer-reviewed.

### Alexandersson, Gurell, Akenine-Möller — Compressing dynamically generated textures on the GPU

| Field        | Value                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| Authors      | Oskar Alexandersson, Christoffer Gurell, Tomas Akenine-Möller (Lund University / TAT)                |
| Venue/Year   | ACM SIGGRAPH 2006 Sketches, p. 80                                                                    |
| DOI or arXiv | [10.1145/1179849.1179949][alexandersson2006]                                                         |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/alexandersson2006-gpu-dynamic-textures.pdf` |
| Open access  | Y (author copy)                                                                                      |

**Claim.** A one-page sketch showing that `S3TC` encoding can run on the GPU
fast enough for textures generated every frame (cube maps, user interfaces). Per
4×4 tile the encoder fits an RGB line through the mean colour along the
principal component, takes the projected extent as the two endpoints and picks
the nearest of the four palette entries per texel. On a 2006 GPU without integer
or bitwise operations, each 32-bit word is emulated with four floats and the
64-bit block is written as two `RGBA8` texels. A 512×512 texture compresses in
25 ms, about 100× faster than the CPU path, at about 2.5 dB lower PSNR because
the GPU version skips the CPU encoder's endpoint refinement. A bandwidth model
(read `x`, write `x/6`, then `x/6` per frame) makes compression pay off from the
second frame.

**Verbatim quote** (p. 1):

> This implies that bandwidth savings occur when n > 1.4, i.e., already on the second frame.

and the missing API piece the authors ask for (p. 1):

> Ideally, we would need a way to inform the graphics driver that “this RGBA8 texture is now an S3TC texture”.

**Relevance to sparkles.** Encoding, not only decoding, belongs on the GPU
whenever the texture is produced there: a `sparkles:shaders` `BC1` compute
kernel for render targets and procedural content, with van Waveren's CPU
encoder as the scalar oracle. The "texture casting" the authors wished for now
exists in Vulkan as an uncompressed view of a block-compressed image
(`VK_IMAGE_CREATE_BLOCK_TEXEL_VIEW_COMPATIBLE_BIT`, Vulkan 1.1), so a
`sparkles:vulkan` encoder can write blocks in place with no readback. The
break-even model is a policy input for the upload layer: compress a dynamic
texture only when it is sampled over more than one or two frames.

**Caveats.** A sketch, not a full paper; one GPU, eight test images, and a
float-emulation workaround that integer compute shaders make obsolete. The 100×
figure compares a reduced-quality GPU encoder with a refining CPU one.

### van Waveren, Castaño — Real-Time YCoCg-DXT Compression

| Field        | Value                                                                                                        |
| ------------ | ------------------------------------------------------------------------------------------------------------ |
| Authors      | J.M.P. van Waveren (id Software), Ignacio Castaño (NVIDIA)                                                   |
| Venue/Year   | White paper, September 14, 2007 (NVIDIA developer site)                                                      |
| DOI or arXiv | none; [NVIDIA PDF][vanwaveren2007]                                                                           |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/vanwaveren2007-real-time-ycocg-dxt-compression.pdf` |
| Open access  | Y                                                                                                            |

**Claim.** Storing luma `Y` in `DXT5`'s high-precision alpha channel and the
`Co`/`Cg` chroma (with a per-block scale) in the colour endpoints gives a large
quality gain over `DXT1` at twice the size, with a cheap colour-space conversion
in the pixel shader. Both CPU (SIMD) and GPU real-time encoders are given.

**Verbatim quote** (p. 1, abstract):

> In particular there is a consistent gain in RGB-PSNR of 6 dB or more for the Kodak Lossless True Color Image Suite.

**Relevance to sparkles.** A reminder that a block format's channels are not
its semantics: the same `BC3` bytes can be RGBA or scaled YCoCg. The
`sparkles:image` descriptor should carry a colour-model/swizzle tag separate from
the block format (the role `KHR_DF_MODEL_*` plays in `KTX2`), and the sampling
side needs a shader-level reconstruction hook.

**Caveats.** Superseded for new content by `BC7`, which reaches similar quality
without shader decoding.

### Munkberg, Clarberg, Hasselgren, Akenine-Möller — HDR texture compression for graphics hardware

| Field        | Value                                                                                                                |
| ------------ | -------------------------------------------------------------------------------------------------------------------- |
| Authors      | Jacob Munkberg, Petrik Clarberg, Jon Hasselgren, Tomas Akenine-Möller                                                |
| Venue/Year   | ACM Transactions on Graphics 25(3) (SIGGRAPH 2006), pp. 698–706                                                      |
| DOI or arXiv | [10.1145/1141911.1141944][munkberg2006]                                                                              |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/munkberg2006-hdr-texture-compression-graphics-hardware.pdf` |
| Open access  | Y (author copy, Lund University)                                                                                     |

**Claim.** Fixed-rate 8 bpp compression of HDR textures is feasible: the paper
first extends `S3TC` to HDR, then proposes a stronger scheme that separates a
log-luminance channel from chrominance and uses shape-template chroma encoding.
Results at 8 bpp are close to uncompressed 48 bpp half-float data.

**Verbatim quote** (p. 1, abstract):

> At a fixed rate of 8 bits per pixel, we obtain results virtually indistinguishable from uncompressed HDR textures at 48 bits per pixel.

**Relevance to sparkles.** Establishes the 8 bpp HDR budget that `BC6H` and
`ASTC` HDR later hit, and that the error metric for HDR must be computed in a
log or tone-mapped domain, not linear RMSE. `sparkles:image` HDR encoders and
round-trip tests need a configurable error space.

**Caveats.** This format was never shipped in hardware; `BC6H` (Direct3D 11, 2009) is a different design, and no public document says it derives from this
work — "precursor" is only chronological. A concurrent paper by Roimela, Aarnio
and Itäranta (SIGGRAPH 2006) proposed another HDR scheme and is not covered here.

### Munkberg, Clarberg, Hasselgren, Akenine-Möller — Practical HDR texture compression

| Field        | Value                                                                                                        |
| ------------ | ------------------------------------------------------------------------------------------------------------ |
| Authors      | Jacob Munkberg, Petrik Clarberg, Jon Hasselgren, Tomas Akenine-Möller                                        |
| Venue/Year   | Computer Graphics Forum 27(6), 2008, pp. 1664–1676                                                           |
| DOI or arXiv | [10.1111/j.1467-8659.2008.01174.x][munkberg2008]                                                             |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/munkberg2008-practical-hdr-texture-compression.pdf` |
| Open access  | Y (author copy, Lund University)                                                                             |

**Claim.** Follows the 2006 work with the engineering issues: fast offline
compression via Procrustes analysis for chroma template fitting, filtering in
the compressed colour space before the colour transform (with a correction to
limit error), and extra block modes.

**Verbatim quote** (p. 1, abstract):

> To reduce the cost of HDR texture filtering, we perform filtering prior to the color transformation, and use a simple trick to reduce the incurred errors.

**Relevance to sparkles.** Filtering order is a correctness issue a software
sampler must decide explicitly: hardware filters _decoded_ texels in the
format's output space, so a `sparkles:image` CPU reference sampler must decode
first, then filter, in the same space (and linearise sRGB before filtering) to
match GPU output in golden tests.

**Caveats.** Same as above: research formats, not shipped. The filtering trick
targets their transform, not `BC6H`.

### Munkberg, Akenine-Möller, Ström — High quality normal map compression

| Field        | Value                                                                                   |
| ------------ | --------------------------------------------------------------------------------------- |
| Authors      | Jacob Munkberg, Tomas Akenine-Möller (Lund University), Jacob Ström (Ericsson Research) |
| Venue/Year   | Graphics Hardware 2006, pp. 95–101                                                      |
| DOI or arXiv | [10.2312/EGGH/EGGH06/095-101][munkberg2006nm] (also ACM `10.1145/1283900.1283916`)      |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/munkberg2006-normal-maps.pdf`  |
| Open access  | Y (author copy)                                                                         |

**Claim.** ATI's `3Dc` (the two-channel format that became `BC5`) stores only
the tangent-space `x` and `y` of a unit normal, each as a `DXT5`-alpha-style
block (two 8-bit endpoints, eight interpolated levels, 3-bit indices), and
rebuilds `z` from the unit-length constraint. The paper adds three techniques
within the same 8 bpp: a rotated coordinate frame per block (a tighter box when
features are diagonal), point distributions chosen by the box's aspect ratio
(for example 16×4 instead of 8×8, signalled for free), and a differential mode
for slowly varying normals. The extra mode bits come from endpoint ordering:
swapping `x_start` and `x_stop` yields the same levels, so the order encodes a
bit. On average PSNR rises by about 3 dB, by 10 dB on one map, and the gain is
visible in renders.

**Verbatim quote** (p. 2):

> The same trick is used in DXT1 to signal whether a block is RGB or RGBA, and we call this trick the ordering technique.

and the reconstruction the format relies on (p. 2):

> Since the length of the normal is not of interest, 3Dc uses units normals, and hence it suffices to compress the x- and y-components.

**Relevance to sparkles.** Two lessons for block decoders and descriptors. The
ordering trick recurs in `DXT1`, `DXT5` alpha, `3Dc` and these extensions, so a
D decoder should treat "which endpoint is larger" as a decoded mode bit, never as
an inconsistency to normalise away. And a two-channel normal map is not an RG
image: the `sparkles:image` descriptor must say "unit normal, `z` reconstructed"
so that both the CPU reference sampler and the `sparkles:shaders` material code
rebuild `z = sqrt(1 − x² − y²)` (clamped) the same way, and so that an encoder
can be told to minimise normal error instead of per-channel RGB error.

**Caveats.** The extended format was not standardised; shipping hardware has
`BC5`, `EAC` `RG11` and `ASTC`. PSNR on the components is a proxy that the
follow-up paper below criticises; 2006 test maps.

### Munkberg, Olsson, Ström, Akenine-Möller — Tight frame normal map compression

| Field        | Value                                                                                          |
| ------------ | ---------------------------------------------------------------------------------------------- |
| Authors      | Jacob Munkberg, Ola Olsson, Jacob Ström, Tomas Akenine-Möller                                  |
| Venue/Year   | Graphics Hardware 2007, pp. 37–40                                                              |
| DOI or arXiv | [10.2312/EGGH/EGGH07/037-040][munkberg2007]                                                    |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/munkberg2007-tight-frame-normals.pdf` |
| Open access  | Y (author copy)                                                                                |

**Claim.** Half the paper is metrology. Normal maps are not viewed directly, so
image metrics mislead: the authors measure PSNR over unit-normal components,
the angular deviation `arccos(n_o · n_c)` (a small angular error can select a
different environment-map texel), the maximum error, and the error histogram,
alongside SSIM on rendered images. The codec half replaces `3Dc`'s axis-aligned
box with an oriented "tight frame": two 7+7-bit points `p` and `q` and a 4-bit
aspect ratio (32 bits) define a rotated box filled with a variable point
distribution, plus 6 index bits per texel, for 128 bits per 4×4. A differential
mode for slowly varying normals uses a non-rotated square with an 11+11-bit
corner and an 8-bit side. Over 20 test maps the aggregate PSNR is 33.50 dB
versus 32.74 dB for enhanced `3Dc` and 30.87 dB for `3Dc`, and maximum angular
error is lower on all but one map. The authors suggest the format as a candidate
for OpenGL ES.

**Verbatim quote** (p. 1):

> We argue that it is important to study not only the PSNR of the resulting maps, but also the maximum pixel error, and the error distribution over the images alongside with rendered results of the maps in use.

and on aggregating a test suite (p. 3):

> Note that it is not correct to simply average the PSNR scores of the individual images, since this is not a linear operator.

**Relevance to sparkles.** This is the specification for `sparkles` codec
quality gates: report mean error, maximum error and a percentile or histogram,
in a metric that matches the texel semantics (angular error for normals), and
aggregate a corpus by averaging MSE before converting to PSNR. A golden-test
helper that only reports mean PSNR per image would hide exactly the isolated bad
normals that show up as specular glints.

**Caveats.** The tight-frame format was not standardised; its decoder is
estimated at up to twice the gate cost of enhanced `3Dc`. All encoders in the
comparison were optimised for MSE, not for the angular metrics the paper
recommends.

### Wennersten, Ström — Table-based alpha compression

| Field        | Value                                                                                          |
| ------------ | ---------------------------------------------------------------------------------------------- |
| Authors      | Per Wennersten, Jacob Ström (Ericsson Research)                                                |
| Venue/Year   | Computer Graphics Forum 28(2) (Eurographics 2009), pp. 687–695                                 |
| DOI or arXiv | [10.1111/j.1467-8659.2009.01409.x][wennersten2009]                                             |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/wennersten2009-alpha-compression.pdf` |
| Open access  | Y (author copy)                                                                                |

**Claim.** Scalar textures (alpha, specular and parallax maps) get their own
codecs built on `ETC`'s idea of a base value plus an indexed offset table. At
2 bpp the scheme beats block truncation coding by over 2 dB; at 1 bpp (the
first public 1 bpp texture codec, per the authors) it beats `DXT5` on a
half-resolution texture by over 2 dB, and rendered scenes stay usable even when
the alpha map itself degrades visibly, for bandwidth savings of up to 75%. At
4 bpp the paper diagnoses `DXT5` alpha's redundancy and replaces its two
interpolated endpoints with an 8-bit base value and an 8-bit table index (a
4-bit multiplier and one of 16 stored tables), about 1 dB better than `DXT5`.

**Verbatim quote** (p. 6):

> Seven out of 256, about 3%, of all possible base value combinations are redundant in this way, producing duplicate entries.

and the evaluation stance (p. 1, abstract):

> the quality of the final rendered images appears to be sufficient for a wide range of applications, thus allowing bandwidth savings of up to 75%.

**Relevance to sparkles.** Single-channel data (masks, roughness, height, font
atlases, video alpha) is where a generic image library overpays by reaching for
colour formats, so the `sparkles:image` encoder API should offer scalar block
paths (`BC4`, `EAC` `R11`) and treat bit rate as an explicit parameter. The 4 bpp
design — base value, multiplier, 16 tables of signed offsets — has the same
shape as `ETC2`'s `EAC` alpha block, so a D `EAC` decoder is again a small
table-driven pure function with tables in `static immutable` data. The
evaluation method (judge the rendered composite, not the alpha map) belongs in
the acceptance tests for mask quality tiers.

**Caveats.** The 1 and 2 bpp codecs never became hardware formats. Rendered-image
sufficiency is application-dependent; alpha-tested foliage is the case most
sensitive to these errors.

### Rasmusson, Ström, Wennersten, Doggett, Akenine-Möller — Texture compression of light maps using smooth profile functions

| Field        | Value                                                                                                                   |
| ------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Authors      | Jim Rasmusson, Jacob Ström, Per Wennersten (Ericsson Research), Michael Doggett, Tomas Akenine-Möller (Lund University) |
| Venue/Year   | High Performance Graphics 2010, pp. 143–152                                                                             |
| DOI or arXiv | [10.2312/EGGH/HPG10/143-152][rasmusson2010]                                                                             |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/rasmusson2010-light-maps.pdf`                                  |
| Open access  | Y (author-made version)                                                                                                 |

**Claim.** Light maps (three per surface under radiosity normal mapping) are
smooth gradients that 4 bpp palette codecs such as `DXT1` and `ETC2` band, and
switching to 8 bpp `BC7` doubles the cost. The proposed 64-bit block lets a
texel's _position_ drive the interpolation between two base colours through one
of four parameterised, rotatable profile functions; one bit per block selects
between this mode and a subset of `ETC2` for noisy blocks. On 24 radiosity
normal maps from the game Mirror's Edge it gains 0.7 dB PSNR over `ETC2` and
2.8 dB over `DXT1` at the same rate, and it also improves many ordinary images.

**Verbatim quote** (p. 2):

> Instead of allowing neighboring pixels to obtain completely different colors, we exploit the spatial redundancy in the data by letting the position of the pixel in the block control the interpolation between two base colors.

and the escape hatch (p. 2):

> For “non-smooth” blocks, we propose using a variant of ETC2 as a fallback.

**Relevance to sparkles.** Smooth content (gradients, baked lighting and
ambient occlusion, UI backgrounds) is where block encoders fail visibly, and
where the encoder's mode choice (planar modes in `ETC2`, void-extent and
weight-grid choices in `ASTC`, partitions in `BC7`) matters more than the format
name. For `sparkles` this argues for content presets (smooth, photo, mask,
normal) in the encoder API, and for a banding-sensitive test image in every
codec's golden corpus.

**Caveats.** Not a shipped format. Test data are one game's 2010 light maps; the
profile functions were chosen partly by trial and error, as the authors say.

### Ström, Wennersten — Lossless compression of already compressed textures

| Field        | Value                                                                                     |
| ------------ | ----------------------------------------------------------------------------------------- |
| Authors      | Jacob Ström, Per Wennersten (Ericsson Research)                                           |
| Venue/Year   | High Performance Graphics 2011, pp. 177–182                                               |
| DOI or arXiv | [10.1145/2018323.2018351][strom2011]                                                      |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/strom2011-lossless-textures.pdf` |
| Open access  | Y (author copy)                                                                           |

**Claim.** Generic compressors treat `ETC1` blocks as opaque bytes, and the
per-pixel indices look like noise even where the image is flat. The packer
instead predicts each pixel's _colour_ from already-decoded neighbours (left,
up, diagonal, with a planar or averaging predictor chosen by local similarity),
tries the four indices the block's table allows, takes the index whose colour is
closest as the prediction, and arithmetic-codes against it; base colours are
predicted the same way. A 4 bpp texture packs to about 2.3 bpp, versus about
3.0 bpp with ZIP and 2.8 bpp with LZMA — the same size as JPEG at equal quality
— while unpacking reproduces the exact block stream.

**Verbatim quote** (p. 3):

> Using the surrounding pixel colors to thus predict the pixel index gives a better guess than just using the surrounding pixel indices.

and the cost it pays (p. 6):

> Also, arithmetic coding is sequential by nature, although different textures can of course be decoded in parallel.

**Relevance to sparkles.** The cleanest statement of the idea that a
supercompression layer can be _lossless with respect to the GPU blocks_ — so the
fixed-rate decoder stays the single source of truth and the supercompressor can
be validated by byte equality. It argues for an image-domain predictor in any
custom `sparkles` block packer rather than plain Zstandard, and its future-work
section already proposes the rate-distortion optimisation that Crunch and
`UASTC` `RDO` later shipped (choose the cheaper of two equally good indices).

**Caveats.** Unoptimised decoding took about 300 ms per 512×512 texture on a
1.33 GHz laptop versus about 60 ms for ZIP. Image-domain prediction is serial
within a texture, which conflicts with GPU-parallel transcoding (the gap `GST`
addresses). Only `ETC1` was evaluated; the packer offers no rate–quality knob.

### Nystad, Lassen, Pomianowski, Ellis, Olson — Adaptive Scalable Texture Compression (`ASTC`)

| Field        | Value                                                                                                          |
| ------------ | -------------------------------------------------------------------------------------------------------------- |
| Authors      | Jorn Nystad, Anders Lassen, Andy Pomianowski, Sean Ellis, Tom Olson (ARM; Pomianowski at AMD)                  |
| Venue/Year   | High Performance Graphics 2012, pp. 105–114                                                                    |
| DOI or arXiv | [10.2312/EGGH/HPG12/105-114][nystad2012]                                                                       |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/nystad2012-adaptive-scalable-texture-compression.pdf` |
| Open access  | Y (Eurographics Digital Library; also a CMU course mirror)                                                     |

**Claim.** One 128-bit block format covers 2D and 3D, LDR and HDR, 1–4
channels and footprints from 4×4 to 12×12 (8 to 0.89 bpp). Flexibility comes
from bounded integer sequence encoding (trits and quints packed so any value
range is stored near-optimally), a weight grid smaller than the block and
bilinearly upsampled, and a hash-based procedural partition function instead of
partition tables.

**Verbatim quote** (p. 1, abstract):

> The system uses bilinear interpolation to derive color space coordinates for a texel from sparse samples, and uses a procedural partition function to map texels to color spaces.

And the design goal of BISE (p. 3):

> Given sequences of equiprobable values in the range 0 to N − 1, find an encoding that allows the ith value to be extracted in constant time with minimal hardware, allows the same hardware to be used with many different ranges of values, and is storage-efficient.

**Relevance to sparkles.** `ASTC` is the most complex block decoder
`sparkles:image` would carry and the one with the largest hostile-input surface:
the Khronos Data Format Specification lists illegal encodings (a weight grid
larger than the block footprint, four partitions with dual-plane mode, reserved
endpoint modes) that must decode to an error colour (opaque magenta for LDR,
NaNs for HDR). A D implementation
should split it into a validated `BlockMode` decode (an `Expected`-returning,
CTFE-testable table builder) and a total texel decoder; BISE unpacking is a
natural target for exhaustive `@ctfe` tests. The block-size-per-texture design
also means the `sparkles` format descriptor needs per-format block footprint,
including 3D.

**Caveats.** Encoding quality depends heavily on search effort (Arm's
`astc-encoder` is the de facto reference). Desktop GPU support for `ASTC`
LDR is patchy; HDR profile support is rarer still. The normative definition is
the Khronos Data Format Specification, not this paper.

### Krajcevski, Pratapa, Manocha — `GST`: GPU-decodable supercompressed textures

| Field        | Value                                                                                                                   |
| ------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Authors      | Pavel Krajcevski, Srihari Pratapa, Dinesh Manocha                                                                       |
| Venue/Year   | ACM Transactions on Graphics 35(6) (SIGGRAPH Asia 2016)                                                                 |
| DOI or arXiv | [10.1145/2980179.2982439][krajcevski2016]                                                                               |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/krajcevski2016-gst-gpu-decodable-supercompressed-textures.pdf` |
| Open access  | Y (UNC GAMMA group page)                                                                                                |

**Claim.** Endpoint-based block formats (`DXT`, `PVRTC`) are split into an
endpoint image (wavelet-transformed) and an index stream (dictionary-coded),
both entropy coded with interleaved rANS streams that decode in parallel on the
GPU. The texture crosses the CPU-GPU bus in supercompressed form and is
re-assembled into hardware blocks on the device, up to 3× faster than earlier
supercompression decoders.

**Verbatim quote** (p. 1, abstract):

> We apply our algorithm to commonly used formats by separating their representation into two parts that are processed independently and then entropy encoded.

**Relevance to sparkles.** The architecture `sparkles` wants for the
storage-to-GPU path: `io_uring` reads the small supercompressed payload, a Vulkan
compute pass expands it into a `VkBuffer` of blocks, and a copy lands it in an
optimally tiled image — the CPU never sees the 4–8 bpp form. It also argues for
ANS with interleaved lanes as the entropy coder of choice for GPU-side decode in
`sparkles:shaders`.

**Caveats.** Research code, never standardised; supports only
endpoint formats, not `BC7`/`ASTC` partitions. `KTX2` did not adopt it.

### Nah — QuickETC2: fast `ETC2` texture compression using luma differences

| Field        | Value                                                                           |
| ------------ | ------------------------------------------------------------------------------- |
| Authors      | Jae-Ho Nah (LG Electronics)                                                     |
| Venue/Year   | ACM Transactions on Graphics 39(6), Article 270 (SIGGRAPH Asia 2020)            |
| DOI or arXiv | [10.1145/3414685.3417787][nah2020]                                              |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/nah2020-quicketc2.pdf` |
| Open access  | Y (author page)                                                                 |

**Claim.** Rather than trying every `ETC1`/`ETC2` mode per block, the encoder
chooses modes early from the block's luma spread and clusters texels for the
`T`/`H` modes in 1D luma instead of 3D RGB. With `AVX2` this compresses over 2000
1K×1K images per second on eight cores, two to three orders of magnitude faster
than `Etc2Comp` and `ETCPACK`.

**Verbatim quote** (p. 1, abstract):

> When clustering each texel into two groups, we replace the 3D RGB space with the 1D luma space and quickly find the two groups that have the minimum luma differences.

**Relevance to sparkles.** Shows that encoder speed comes from pruning the mode
search, not only SIMD; a `sparkles:image` encoder API should expose an effort
level that maps to such pruning. The luma heuristic is a cheap, testable pure
function suitable for `@nogc` SIMD code.

**Caveats.** Built on `etcpak`. In full-`ETC2` mode it averages 0.72–1.47 dB
lower PSNR than `Etc2Comp` and `ETCPACK`; the paper attributes the gap to
`etcpak`'s high-speed `ETC1` path and leaves `EAC` (one- and two-channel)
compression untouched. x86-only implementation; single-vendor evaluation.

### Vaidyanathan et al. — Random-access neural compression of material textures (NTC)

| Field        | Value                                                                                                                             |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Karthik Vaidyanathan, Marco Salvi, Bartlomiej Wronski, Tomas Akenine-Möller, Pontus Ebelin, Aaron Lefohn (NVIDIA)                 |
| Venue/Year   | ACM Transactions on Graphics 42(4) (SIGGRAPH 2023)                                                                                |
| DOI or arXiv | [10.1145/3592407][vaidyanathan2023], [arXiv:2305.17105][vaidyanathan2023arxiv]                                                    |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/vaidyanathan2023-random-access-neural-compression-material-textures.pdf` |
| Open access  | Y (arXiv)                                                                                                                         |

**Claim.** All textures of a material plus their mip chains are encoded jointly
as quantised latent grids and decoded per texel by a tiny per-material MLP run
in the shader with tensor-core matrix ops. At similar memory to `BC` formats
this delivers about 16× more texels, beating AVIF and JPEG XL at low rates, while
keeping per-texel random access.

**Verbatim quote** (p. 1, abstract):

> At the same time, our method allows on-demand, real-time decompression with random access similar to block texture compression on GPUs

and the cost it pays (p. 7):

> Therefore, we cannot rely on hardware acceleration for trilinear filtering and we implement it in software on the GPU.

**Relevance to sparkles.** Neural texture codecs are a _sampling-time_ codec,
not a load-time one: they bypass the texture unit, so they belong in
`sparkles:shaders` as a material-evaluation module, not in the
`sparkles:image` decode path. For `sparkles` the near-term lesson is the format
boundary: a container must be able to carry non-block payloads (latents plus
weights) next to `BCn` fallbacks.

**Caveats.** Requires cooperative-matrix hardware and shader extensions
(`VK_NV_cooperative_matrix` then); no hardware filtering; per-material training
takes minutes on an RTX 4090. NVIDIA later shipped an NTC SDK; its licence was
not checked here.

### Weinreich, De Oliveira, Houdard, Nader — Real-time neural materials using block-compressed features

| Field        | Value                                                                                                                            |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | C. Weinreich, L. De Oliveira, A. Houdard, G. Nader (Ubisoft La Forge)                                                            |
| Venue/Year   | Computer Graphics Forum 43(2) (Eurographics 2024)                                                                                |
| DOI or arXiv | [10.1111/cgf.15013][weinreich2024], [arXiv:2311.16121][weinreich2024arxiv]                                                       |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/weinreich2024-real-time-neural-materials-block-compressed-features.pdf` |
| Open access  | Y (arXiv)                                                                                                                        |

**Claim.** Neural material features are trained _through_ an emulated `BC6`
decoder so that the learned latents can be exported as ordinary `BC6H`
textures; the hardware sampler then filters them, and a small MLP in the shader
decodes the material. This recovers hardware filtering that NTC gave up.

**Verbatim quote** (p. 1, abstract):

> we organize the features in a block-based manner and emulate BC6 decompression during training, making it possible to export them as regular BC6 textures.

**Relevance to sparkles.** A strong argument for a bit-exact, differentiable-
friendly reference `BC6H` decoder: training frameworks need it, and a D
implementation verified against hardware output can serve as the oracle. Also
shows `BC6H` used for non-colour data, so the `sparkles` descriptor must not
assume `BC6H` means "HDR RGB".

**Caveats.** Single-studio results; quality depends on per-material training.

### Fujieda, Harada — Neural texture block compression (NTBC)

| Field        | Value                                                                                                      |
| ------------ | ---------------------------------------------------------------------------------------------------------- |
| Authors      | Shin Fujieda, Takahiro Harada (AMD)                                                                        |
| Venue/Year   | Eurographics Workshop on Material Appearance Modeling (MAM) 2024                                           |
| DOI or arXiv | [10.2312/mam.20241178][fujieda2024], [arXiv:2407.09543][fujieda2024arxiv]                                  |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/fujieda2024-neural-texture-block-compression.pdf` |
| Open access  | Y (arXiv; Eurographics Digital Library)                                                                    |

**Claim.** Instead of replacing block formats, a small per-material network is
stored on disk and, at load time, regenerates the `BC1`/`BC4` endpoints and
indices for all textures of the material (the paper evaluates only `BC1` and
`BC4`, leaving `BC6H`/`BC7` to future work). Shaders are unchanged; storage
drops by up to about 70% at reasonable quality.

**Verbatim quote** (p. 1, abstract):

> NTBC learns the mapping from uncompressed textures to block-compressed textures, which allows for significantly reduced storage costs without any change in the shaders.

**Relevance to sparkles.** Neural _supercompression_: the GPU still receives
standard blocks, so it plugs into the same load-time transcode stage as Basis
or `GST` (a compute pass producing blocks), not the sampler. It frames neural
methods as one more `KTX2`-style supercompression scheme.

**Caveats.** Workshop-level venue; lossy relative to a reference `BC` encode;
load-time inference cost must be budgeted.

### Zhuang, Liu, Liu — Differentiable block compression for neural texture (DBC)

| Field        | Value                                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------------------ |
| Authors      | Tao Zhuang, Wentao Liu, Ligang Liu (Tencent, USTC)                                                                       |
| Venue/Year   | Eurographics Symposium on Rendering 2025                                                                                 |
| DOI or arXiv | [10.2312/sr.20251199][zhuang2025]                                                                                        |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/zhuang2025-differentiable-block-compression-neural-texture.pdf` |
| Open access  | Y (CC BY, Eurographics Digital Library)                                                                                  |

**Claim.** Conventional `BC` encoders minimise per-texel error, which is the
wrong objective when the texture feeds a neural decoder; DBC makes the encoder
differentiable (stochastic selection among partition/mode configurations, a
"mixture of partitions" module) and trains it end to end with the network.

**Verbatim quote** (p. 1, abstract):

> mainstream block compression encoders only aim to minimize compression errors. This design may significantly increase neural network model loss.

**Relevance to sparkles.** Encoder objectives should be pluggable: a
`sparkles:image` encoder API that accepts a caller-supplied error metric
(per-channel weights, perceptual or task loss) generalises RDO, YCoCg weighting,
normal-map angular error and DBC-style goals with one seam.

**Caveats.** Recent, unreplicated; evaluated on neural material pipelines only.

### Microsoft — `BC6H` and `BC7` format documentation

| Field        | Value                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------- |
| Authors      | Microsoft (Direct3D 11 documentation)                                                       |
| Venue/Year   | Web documentation for Direct3D 11 (`ms.date` 2018); `BC6H` page last updated March 11, 2025 |
| DOI or arXiv | none; [`BC6H` format][msbc6h], [`BC7` format][msbc7]                                        |
| Local PDF    | web source                                                                                  |
| Open access  | Y                                                                                           |

**Claim.** `BC6H` packs RGB half-float (signed `SF16` or unsigned `UF16`) into
128-bit 4×4 blocks with 14 modes, one or two regions and delta-coded,
sign-extended endpoints, identified by a 2- or 5-bit mode field; `BC7` packs
LDR RGBA with eight modes, up to three partitions and optional channel
rotation, and selects the mode with a unary prefix (zero or more 0 bits, then a

1. in the least significant bits.

**Verbatim quote** (web page, `BC6H` page):

> Modes 10011, 10111, 11011, and 11111 (not shown) are reserved. Do not use these in your encoder. If the hardware is passed blocks with one of these modes specified, the resulting decompressed block must contain all zeroes in all channels except for the alpha channel.

**Relevance to sparkles.** This is the totality requirement for block decoders
stated as normative behaviour: every 128-bit pattern has a defined output, so a
D decoder must have no `assert(false)` paths reachable from data, and fuzzing
should compare against hardware readback. The same page notes `BC6H` has no INF
or NaN (signed mode can produce −INF), so `sparkles` HDR pipelines must not
assume finite-only or NaN-free semantics blindly.

**Caveats.** Vendor documentation with pseudo-code that has historically had
errata; the Khronos Data Format Specification is the cross-API reference.

### Khronos — Data Format Specification 1.4

| Field        | Value                                            |
| ------------ | ------------------------------------------------ |
| Authors      | Andrew Garrard (editor), The Khronos Group       |
| Venue/Year   | Khronos specification, version 1.4.0 (2014–2025) |
| DOI or arXiv | none; [HTML specification][kdfs]                 |
| Local PDF    | web source                                       |
| Open access  | Y                                                |

**Claim.** Defines data format descriptors (colour model, channels, sample
bit positions, transfer function, primaries) for both linear and block formats,
and contains normative decode descriptions of `S3TC`, `RGTC`, `BPTC`
(`BC6H`/`BC7`), `ETC1`, `ETC2`/`EAC`, `ASTC`, `PVRTC` and `UASTC`.

**Verbatim quote** (web page, chapter 17):

> In this context, “texture compression” is distinct from “image compression” in that texture compression schemes are designed to allow efficient random access as part of texture sampling

and a hostile-input detail (web page, `BC4` signed):

> Encoders for the signed red-green formats should avoid encoding blocks where red0 = -127 and red1 = -128.

**Relevance to sparkles.** The single document a `sparkles:image` block-codec
module should cite per decoder, and the model for the format descriptor type:
`KTX2` embeds exactly this descriptor, so parsing the DFD block is mandatory for
`KTX2` and gives `sparkles` a ready-made, standard vocabulary for colour model,
transfer function and primaries. The `BC4` signed caveat shows that some inputs
are _implementation-defined_, so golden tests must exclude them or accept
either result.

**Caveats.** Not a ratified Khronos specification (its own licence text says
so); text derived from OpenGL extensions, and some sections lag hardware.

### Khronos — KTX File Format Specification 2.0

| Field        | Value                                                                     |
| ------------ | ------------------------------------------------------------------------- |
| Authors      | Mark Callow (editor), The Khronos Group                                   |
| Venue/Year   | Khronos specification, version 2.0.4 (document revision 4, February 2025) |
| DOI or arXiv | none; [HTML specification][ktx2]                                          |
| Local PDF    | web source                                                                |
| Open access  | Y                                                                         |

**Claim.** `KTX2` stores a `VkFormat`, a Data Format Descriptor, key/value
metadata and an index of mip levels, each optionally supercompressed with
`BasisLZ` (scheme 1), Zstandard (2) or ZLIB (3). Levels are stored smallest
first and supercompressed independently so a reader can stream or seek to a
single mip.

**Verbatim quote** (web page, header field `supercompressionScheme`):

> The supercompression scheme is applied independently to each mip level to permit streaming and random access to the levels.

and on robustness (section 4.3, Extending KTX):

> Consumers of KTX files must fail gracefully when encountering formats or supercompression schemes they are not prepared to handle.

**Relevance to sparkles.** `KTX2` is the natural on-disk container for
`sparkles:image` block planes: its header and level index are a fixed-layout
binary structure that `wired` can describe and validate (offsets within file,
`byteLength` versus `uncompressedByteLength`, alignment equal to `lcm(block
size, 4)` when not supercompressed), while level payloads are handed to the
right decompressor. The level index gives `event-horizon` exactly the
`(offset, length)` pairs to submit as independent `io_uring` reads, and smallest-
first ordering lets a viewer show low mips while larger ones load.

**Caveats.** `BasisLZ` global data couples all levels to one codebook, so it
breaks the "independent level" property in practice; `uncompressedByteLength`
is attacker-controlled and must be bounded before allocation.

### Callow — Compressed texture transmission: `KTX2` and Basis Universal

| Field        | Value                                                                                         |
| ------------ | --------------------------------------------------------------------------------------------- |
| Authors      | Mark Callow (presenting Basis Universal, credited to Rich Geldreich, Binomial)                |
| Venue/Year   | SIGGRAPH 2019 Khronos presentation, Los Angeles, July 31, 2019                                |
| DOI or arXiv | none; [Khronos slide deck][callow2019]                                                        |
| Local PDF    | `~/code/repos/papers/image-video/gpu-texture-compression/callow2019-ktx2-basis-universal.pdf` |
| Open access  | Y (Khronos presentation PDF)                                                                  |

**Claim.** The deck states the two problems the `KTX2` + Basis Universal
pipeline addresses — the size of block-compressed assets and the need for one
asset version per GPU format — and the pipeline itself: encode to `ETC1S` and
supercompress (`toktx`), store the Basis Universal payload in `KTX2`, then
inflate and transcode at load time (`libktx`) to `BC1`–`BC5`, `ETC1`/`ETC2`,
`PVRTC` or `ASTC` (4×4 and 8×8 targets marked "under development"). Two
comparisons (a 2048×2048 drawing and the Kodak `kodim17` photo) set the
`ETC1S` file size against JPEG and PNG and report PSNR and SSIM after
transcoding to `ETC2`. glTF is announced as adopting `KTX2`.

**Verbatim quote** (p. 2):

> the need for multiple GPU-specific versions of those assets?

and the glTF commitment (p. 8):

> with Basis Universal payload for compressed texture transmission

**Relevance to sparkles.** This is the interop path `sparkles` must support for
glTF assets: parse `KTX2`, inflate, transcode to whatever block format the
`sparkles:vulkan` device reports, upload. Each stage is a separate `sparkles`
component — bounded container parsing, the supercompression layer, a block
transcoder that is mostly table and bit-field rewriting (a good
`sparkles:shaders` candidate), and the staging upload.

**Caveats.** A 2019 presentation, not a paper: two images, pre-final
specification, and only `ETC1S` is shown (`UASTC` is not mentioned). Current
codec behaviour must be taken from the Basis Universal specifications below.

### Geldreich (Binomial) — Basis Universal specifications, Crunch and the RDO lineage

| Field        | Value                                                                                                                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Rich Geldreich (Binomial LLC)                                                                                                                                                                           |
| Venue/Year   | [`UASTC` LDR 4x4 specification][uastc] (2020), [`.basis` / `ETC1S` specification][etc1s] (v1.03), [Crunch README][crunch] (2011–), [The Three Generations of GPU Texture Distribution][threegen] (2026) |
| DOI or arXiv | none (GitHub wiki pages, archived, and repository README)                                                                                                                                               |
| Local PDF    | web source                                                                                                                                                                                              |
| Open access  | Y (specifications public domain / CC0)                                                                                                                                                                  |

**Claim.** Crunch introduced two supercompression routes for `DXT1`, `DXT5`, `DXT5A` and
`DXN`/`3DC` (`BC1`, `BC3`–`BC5`):
`.CRN` (VQ clustering of endpoints and selectors, then entropy coding) and
"clustered" or RDO `.DDS` files whose blocks are deliberately made redundant so
a generic LZ compressor shrinks them. Basis Universal turned this into
transcodable intermediates: `ETC1S` (VQ codebooks + Huffman, transcodes to any
format) and `UASTC` (a 19-mode subset of 4×4 `ASTC`, losslessly convertible to
`ASTC` and cheaply to `BC7`, optionally RDO-encoded for Zstandard), both
standardised in `KTX2`.

**Verbatim quotes** (web pages):

> To actually benefit from clustered DXTn .DDS files, your engine needs to further losslessly compress the .DDS data generated by crnlib using a lossless codec such as zlib, lzo, LZMA, LZHAM, etc.

(Crunch README)

> Transcoding can either be done using the CPU or with a GPU compute shader.

(`UASTC` LDR 4x4 specification)

> It's optional for transcoders/decoders to validate this CRC-16.

(`.basis` specification, slice CRC)

> Ship a compact intermediate. Compile locally. Cache the execution format.

(The Three Generations of GPU Texture Distribution)

**Relevance to sparkles.** RDO is an _encoder-only_ concern: the decoder sees
standard blocks, so `sparkles` can ship a plain `BCn` decoder plus Zstandard and
still consume RDO content. A `UASTC`→`BC7`/`ASTC` transcoder is the single most
valuable piece for portability and is a good compute-shader candidate. The
"compile locally, cache the execution format" model suggests a `sparkles`
asset cache keyed by content digest and target GPU format. The optional CRC is a
reminder that integrity checks are not validation: the Huffman and codebook
parsers must be bounds-checked regardless.

**Caveats.** Vendor documentation, not peer-reviewed; quality and speed claims
are the author's. The 2026 "Three Generations" page describes Basis v2.0/v2.50
codecs (`XUASTC`, `XUBC7`) that are too new to have independent evaluation.

## Thread synthesis

**Consensus.** Every hardware format since `S3TC` is fixed-rate and
block-addressable, because the texture unit needs random access; the variation
is in how a 64- or 128-bit block spends its bits (endpoints + indices for
`BCn`, base colour + luminance tables for `ETC`, a fully parameterised block
mode for `ASTC`, neighbour-blended signals for `PVRTC`). The literature agrees
that variable-rate gains must therefore live in a separate layer above the
blocks — lossless repacking (Ström and Wennersten), RDO+LZ and VQ (Crunch,
`ETC1S`), GPU-decodable entropy coding (`GST`), or transcodable intermediates
(`UASTC`) — and `KTX2` standardises that two-layer split (Callow's 2019 deck is
the pipeline as first shipped). HDR at 8 bpp is settled (`BC6H`, `ASTC` HDR).
The Lund/Ericsson line agrees on a second point: at equal rate, a block model
and an error metric built for the texel's meaning beat a generic colour codec —
about 3 dB for normal maps, 0.7–2.8 dB for light maps, usable alpha at 1–2 bpp
(Munkberg et al. 2006, 2007; Wennersten and Ström; Rasmusson et al.) — and two
tricks recur throughout: reusing redundant encodings (endpoint ordering,
`ETC2`'s invalid deltas, `DXT5`'s duplicate levels) as extra modes, and
reconstruction in the shader (normal `z`, YCoCg).

**Disagreements.** Where the second layer should decode: CPU at install time
(Basis, "compile locally"), GPU compute at upload (`GST`, `UASTC` compute
transcoders), or in the shader at sample time (NTC). Where encoding runs: offline
with exhaustive search, at run time on the CPU (van Waveren, QuickETC2), or on
the GPU next to the producer (Alexandersson et al.). Whether learned methods
should replace blocks (NTC) or produce them (NTBC, Weinreich et al., DBC); the
block-producing camp keeps hardware filtering, the replacing camp gets better
rate-distortion but pays in filtering and hardware requirements. Whether
per-semantic formats are worth their silicon or one flexible format (`ASTC`,
with partitions, dual planes and 1–4 channels) should absorb them; the research
formats for normals, alpha and light maps were not standardised, but their ideas
recur in `EAC` and `ASTC`. Image-domain prediction (Ström and Wennersten)
compresses better but is serial; `GST` trades some of that for parallel ANS
decode.

**Open problems.** Fast high-quality `ASTC`/`BC7` encoding; standard neural
texture formats (nothing is in `KTX2` yet); HDR supercompression (`UASTC` HDR
is recent); error metrics for non-colour data (normals, roughness, neural
features) that track rendered artefacts — specular glints, banding on smooth
gradients — rather than mean PSNR, and encoders that optimise them (the
2007 comparison still optimised every encoder for MSE); and bit-exact
cross-vendor decoding for implementation-defined corners (`BC4` signed, `BC6H`
rounding, `ETC2` emulation on desktop).

**What a D implementation should take from this:**

- Model block planes as a first-class image kind: a descriptor with block
  footprint (including 3D `ASTC`), bytes per block, colour model, transfer
  function and signedness, borrowed from the Khronos DFD rather than invented —
  plus a texel-semantics tag (colour, unit normal with reconstructed `z`, scalar
  mask, light map, neural feature) that selects the encoder's error metric and
  the reconstruction step.
- Make every block decoder a total, `@safe pure nothrow @nogc` function over
  `ubyte[8]`/`ubyte[16]` with specified outputs for reserved modes (`BC6H`
  zeroes, `ASTC` error colour), wide arithmetic for `ETC2` invalid-delta
  escapes, and endpoint order decoded as a mode bit; test exhaustively where the
  space is small and fuzz against hardware readback where it is not.
- Keep three layers separate in code: fixed-rate block codecs, a
  supercompression layer (Zstandard, `BasisLZ`, later `GST`-style ANS), and the
  `KTX2` container parsed with `wired`-style bounded descriptions that check
  every offset, length and `uncompressedByteLength` before allocating.
- Use `KTX2`'s per-level independence for streaming: `event-horizon` issues one
  read per mip level (smallest first), and a Vulkan staging/copy path uploads
  each level as it lands.
- Put transcoders (`UASTC`→`BC7`/`ASTC`, `ETC1S`→anything) and a run-time `BC1`
  encoder for render targets in `sparkles:shaders` compute kernels, writing
  through a block-texel-compatible view, with a CPU reference in D as the oracle.
- Offer encoders in effort tiers and content presets — van Waveren-style
  bounding-box SIMD for run-time, mode-pruned search (QuickETC2) for build time;
  smooth, photo, mask and normal presets — behind one API that takes a pluggable
  error metric so RDO, perceptual weighting, angular error and task losses share
  a seam.
- Gate codec quality on mean, maximum and percentile error in the semantic's
  metric, aggregate a corpus by averaging MSE before converting to PSNR, and
  include a smooth-gradient image in every golden corpus.
- Reserve codepoints in any `sparkles`-defined block or container format, and
  document shader-side reconstruction (normal renormalisation, YCoCg, packed
  channels) as part of each format's contract.
- Treat neural texture compression as a shader-side material module and a
  future `KTX2` payload type, not part of the near-term image decode path.

## Sources

- [Iourcha et al., US 5,956,431][us5956431]
- [Fenney 2003, `PVRTC`][fenney2003]
- [Ström and Akenine-Möller 2005, iPACKMAN][strom2005]
- [Ström and Pettersson 2007, `ETC2`][strom2007]
- [van Waveren 2006, Real-Time DXT Compression][vanwaveren2006]
- [Alexandersson et al. 2006, compressing dynamically generated textures on the GPU][alexandersson2006]
- [van Waveren and Castaño 2007, Real-Time YCoCg-DXT Compression][vanwaveren2007]
- [Munkberg et al. 2006, HDR texture compression][munkberg2006]
- [Munkberg et al. 2008, Practical HDR texture compression][munkberg2008]
- [Munkberg et al. 2006, high quality normal map compression][munkberg2006nm]
- [Munkberg et al. 2007, tight frame normal map compression][munkberg2007]
- [Wennersten and Ström 2009, table-based alpha compression][wennersten2009]
- [Rasmusson et al. 2010, light maps with smooth profile functions][rasmusson2010]
- [Ström and Wennersten 2011, lossless compression of compressed textures][strom2011] ([abstract record][strom2011eg])
- [Nystad et al. 2012, `ASTC`][nystad2012]
- [Krajcevski et al. 2016, `GST`][krajcevski2016]
- [Nah 2020, QuickETC2][nah2020]
- [Vaidyanathan et al. 2023, NTC][vaidyanathan2023] ([arXiv][vaidyanathan2023arxiv])
- [Weinreich et al. 2024, block-compressed neural features][weinreich2024] ([arXiv][weinreich2024arxiv])
- [Fujieda and Harada 2024, NTBC][fujieda2024] ([arXiv][fujieda2024arxiv])
- [Zhuang et al. 2025, DBC][zhuang2025]
- [Microsoft, `BC6H` format][msbc6h]; [`BC7` format][msbc7]
- [Khronos Data Format Specification 1.4][kdfs]
- [KTX 2.0 specification][ktx2]
- [Callow 2019, `KTX2` and Basis Universal][callow2019]
- [`UASTC` LDR 4x4 specification][uastc]; [`.basis` / `ETC1S` specification][etc1s]; [Crunch README][crunch]; [Three Generations of GPU Texture Distribution][threegen]

<!-- References -->

[us5956431]: https://patents.google.com/patent/US5956431A/en
[fenney2003]: https://doi.org/10.2312/EGGH03/084-091
[strom2005]: https://doi.org/10.2312/EGGH/EGGH05/063-070
[strom2007]: https://doi.org/10.2312/EGGH/EGGH07/049-054
[vanwaveren2006]: https://www.quaddicted.com/webarchive/mrelusive.com_20170131/publications/papers/Real-Time-Dxt-Compression.pdf
[alexandersson2006]: https://doi.org/10.1145/1179849.1179949
[vanwaveren2007]: https://developer.download.nvidia.com/whitepapers/2007/Real-Time-YCoCg-DXT-Compression/Real-Time%20YCoCg-DXT%20Compression.pdf
[munkberg2006]: https://doi.org/10.1145/1141911.1141944
[munkberg2008]: https://doi.org/10.1111/j.1467-8659.2008.01174.x
[munkberg2006nm]: https://doi.org/10.2312/EGGH/EGGH06/095-101
[munkberg2007]: https://doi.org/10.2312/EGGH/EGGH07/037-040
[wennersten2009]: https://doi.org/10.1111/j.1467-8659.2009.01409.x
[rasmusson2010]: https://doi.org/10.2312/EGGH/HPG10/143-152
[strom2011]: https://doi.org/10.1145/2018323.2018351
[strom2011eg]: https://diglib.eg.org/items/5b8c3d45-ae62-41b8-87b3-61614813c64c
[nystad2012]: https://doi.org/10.2312/EGGH/HPG12/105-114
[krajcevski2016]: https://doi.org/10.1145/2980179.2982439
[nah2020]: https://doi.org/10.1145/3414685.3417787
[vaidyanathan2023]: https://doi.org/10.1145/3592407
[vaidyanathan2023arxiv]: https://arxiv.org/abs/2305.17105
[weinreich2024]: https://doi.org/10.1111/cgf.15013
[weinreich2024arxiv]: https://arxiv.org/abs/2311.16121
[fujieda2024]: https://doi.org/10.2312/mam.20241178
[fujieda2024arxiv]: https://arxiv.org/abs/2407.09543
[zhuang2025]: https://doi.org/10.2312/sr.20251199
[msbc6h]: https://learn.microsoft.com/en-us/windows/win32/direct3d11/bc6h-format
[msbc7]: https://learn.microsoft.com/en-us/windows/win32/direct3d11/bc7-format
[kdfs]: https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.html
[ktx2]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html
[callow2019]: https://www.khronos.org/assets/uploads/developers/presentations/glTF-KTX2-Basis-SIGGRAPH_Jul19.pdf
[uastc]: https://web.archive.org/web/20260813102932/https://github.com/BinomialLLC/basis_universal/wiki/UASTC-LDR-4x4-Texture-Specification
[etc1s]: https://web.archive.org/web/20260921094142/https://github.com/BinomialLLC/basis_universal/wiki/.basis-File-Format-and-ETC1S-Texture-Video-Specification
[crunch]: https://github.com/BinomialLLC/crunch/blob/36479bc697be19168daafbf15f47f3c60ccec004/README.md
[threegen]: https://web.archive.org/web/20260813103100/https://github.com/BinomialLLC/basis_universal/wiki/The-Three-Generations-of-GPU-Texture-Distribution
