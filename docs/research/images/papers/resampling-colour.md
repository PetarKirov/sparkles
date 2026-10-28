# Papers: resampling, compositing and colour

The sources a pixel pipeline must agree with before it may claim to resample,
blend or convert colour correctly: the reconstruction-filter literature, the
premultiplied-alpha algebra, and the colour and HDR signal standards that fix
what a decoded sample means.

| Field              | Value                                                                                                                                                                |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Thread             | `resampling-colour`                                                                                                                                                  |
| Scope              | Resampling kernels, compositing and colour science: reconstruction filters, premultiplied alpha, colour appearance, HDR transfer functions, gamut mapping, ICC, CICP |
| Entries            | 23                                                                                                                                                                   |
| **Last reviewed:** | October 28, 2026                                                                                                                                                     |

> [!NOTE]
> Quote page numbers are PDF page indices of the local copy ("p. N" counts
> from the first page of the PDF file, not the printed folio). Entries without
> a local PDF quote a web page or abstract record, which is unpaginated, except
> Keys, whose printed page is given. Heckbert's quote is read from an OCR pass
> over a scanned PDF without a text layer, checked against the page image, and
> one entry has no quote at all (no open full text or abstract).

## Why this thread matters to sparkles

Every generic algorithm in `sparkles:image` — scale, rotate, blur, composite,
convert — silently commits to a signal model: where a sample sits, what kernel
reconstructs between samples, whether colour values are linear-light or encoded,
whether alpha has been multiplied in, and which primaries, white point and
transfer function a code value refers to. Getting the model wrong is not a
performance bug but a correctness one (dark fringes, hue shifts, banding,
clipped HDR), and it leaks through every layer: the **generic image
abstractions** must carry colour and alpha semantics in the type, the **codec
architecture** must surface CICP/ICC/gain-map metadata instead of discarding it,
**SIMD** and **GPU compute** kernels (`sparkles:shaders`) need separable,
fixed-support filters with exact edge rules so CPU and GPU agree within a
stated tolerance, **hostile input** reaches the colour layer as attacker-chosen
ICC tags, reserved CICP code points and degenerate gain-map metadata, and
**storage-to-GPU I/O** decides whether conversion happens before upload or in a
shader. This thread collects the primary sources for those decisions.

## Annotated bibliography

### Keys 1981 — Cubic convolution interpolation for digital image processing

| Field        | Value                                                                                    |
| ------------ | ---------------------------------------------------------------------------------------- |
| Authors      | Robert G. Keys                                                                           |
| Venue/Year   | IEEE Transactions on Acoustics, Speech, and Signal Processing 29(6), pp. 1153–1160, 1981 |
| DOI or arXiv | [10.1109/TASSP.1981.1163711][keys]                                                       |
| Local PDF    | no open PDF                                                                              |
| Open access  | N                                                                                        |

**Claim.** Derives the piecewise-cubic interpolation kernel with support four
samples that interpolates the data exactly, is continuously differentiable, and
matches the Taylor expansion as far as possible; the unique choice (free
parameter `a = -1/2`) gives third-order convergence. Boundary conditions are
derived so the edge samples keep that order of accuracy. Separable application
gives the 2-D "bicubic" filter.

**Verbatim quote** (abstract, printed p. 1153):

> it can be shown that the order of accuracy of the cubic convolution method is between that of linear interpolation and that of cubic splines.

**Relevance to sparkles.** This is the `a = -0.5` "Catmull-Rom-like" cubic that
most libraries ship as "bicubic"; `sparkles:image` should name kernels by their
parameters (`CubicKernel!(B, C)`) rather than by the ambiguous word "bicubic",
and implement Keys' boundary extrapolation as one of the explicit edge policies
next to clamp/reflect/wrap.

**Caveats.** The copies found online are IEEE Xplore downloads carrying an
institutional licence stamp, so none is cited as a local PDF; obtain it via the
DOI. Keys optimises approximation order for smooth signals, not perceived
quality — see Mitchell–Netravali.

### Mitchell and Netravali 1988 — Reconstruction filters in computer graphics

| Field        | Value                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------- |
| Authors      | Don P. Mitchell, Arun N. Netravali                                                          |
| Venue/Year   | SIGGRAPH '88 / Computer Graphics 22(4), pp. 221–228, 1988                                   |
| DOI or arXiv | [10.1145/54852.378514][mitchell]                                                            |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/mitchell1988-reconstruction-filters.pdf` |
| Open access  | N (publisher); scanned copies circulate on course pages                                     |

**Claim.** Defines the two-parameter `(B, C)` family of piecewise cubics that
contains the cubic B-spline and Catmull-Rom, and classifies their artifacts as
blurring, ringing and anisotropy. A small expert-observer study maps the
parameter plane; the line `B + 2C = 1` gives quadratic convergence and
`(1/3, 1/3)` is recommended as a compromise. It also separates post-aliasing
from the other artifacts.

**Verbatim quote** (p. 4):

> The filter (1/3, 1/3) used to generate Figure 12 is recommended by the authors, but other observers may prefer more or less ringing.

**Relevance to sparkles.** One kernel template parameterised by `(B, C)`
covers B-spline, Catmull-Rom/Keys and Mitchell; the weights can be computed at
compile time per scale factor and fed to both a SIMD separable pass and a
`sparkles:shaders` compute pass. The default should be stated as a choice, not
as "the best" filter.

**Caveats.** Subjective test with nine expert observers (over 500 samples) on
images magnified from 64×64; the authors themselves note the recommended
filter has only fair antialiasing properties against postaliasing.

### Turkowski 1990 — Filters for common resampling tasks

| Field        | Value                                                                                                     |
| ------------ | --------------------------------------------------------------------------------------------------------- |
| Authors      | Ken Turkowski                                                                                             |
| Venue/Year   | Graphics Gems (ed. A. Glassner), Academic Press, pp. 147–165, 1990                                        |
| DOI or arXiv | [10.1016/B978-0-08-050753-8.50042-5][turkowski]                                                           |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/turkowski1990-filters-for-common-resampling-tasks.pdf` |
| Open access  | Y (author's preprint, 10 April 1990)                                                                      |

**Claim.** Tabulates sampled box, tent, Gaussian and Lanczos-windowed sinc
filters for integer interpolation and decimation ratios (2, 3, 4), with zero-
and half-phase variants, and compares their frequency responses. Sampling a
continuous filter changes its character, so names of sampled filters are
misnomers. Lanczos filters best balance passband retention and stopband
rejection.

**Verbatim quote** (p. 9, footnote citing Ampex experiments):

> The Lanczos-windowed sinc functions offered the best compromise in terms of reduction of aliasing, sharpness, and minimal ringing.

**Relevance to sparkles.** Integer-ratio decimation (mip chains, 2× thumbnails,
chroma downsampling) deserves dedicated fixed-tap kernels with explicit phase,
which vectorise as constant-weight dot products; the general-ratio path can be
separate. Phase (co-sited vs centred) must be part of the kernel's type, since
chroma siting in CICP-tagged video depends on it.

**Caveats.** The headline Lanczos finding is a citation of unpublished 1979
Ampex experiments (Turkowski with Steve Gabriel); frequency plots, not
perceptual tests, support the rest.

### Heckbert 1989 — Fundamentals of texture mapping and image warping

| Field        | Value                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------- |
| Authors      | Paul S. Heckbert                                                                                  |
| Venue/Year   | Master's thesis, UC Berkeley, Technical Report UCB/CSD 89/516, 1989                               |
| DOI or arXiv | none (technical report; [Berkeley EECS record][heckbert])                                         |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/heckbert1989-fundamentals-texture-mapping.pdf` |
| Open access  | Y (Berkeley EECS technical reports)                                                               |

**Claim.** Frames image warping as resampling: reconstruct the discrete input
to a continuous signal, warp it, prefilter it to the output's band limit, and
sample. Combining reconstruction and prefilter gives one resampling filter,
space invariant for affine mappings and space variant otherwise; elliptical
Gaussians under the local affine (Jacobian) approximation then justify the
elliptical weighted average (EWA) filter of Greene and Heckbert (1986) for
arbitrary (including projective) mappings. Also catalogues affine, bilinear
and projective mappings and their inverses.

**Verbatim quote** (p. 3, abstract; OCR of the scan):

> For resampling, this work develops a new theory describing the ideal, space variant antialiasing filter for signals warped and resampled according to an arbitrary mapping.

**Relevance to sparkles.** The reconstruct–warp–prefilter–sample decomposition
is the right shape for a generic `warp(image, mapping, filter)` API: the
mapping supplies a local Jacobian, the filter supplies a footprint, and the
scaler/rotator become special cases rather than separate code paths. EWA is
the reference against which a GPU anisotropic-sampling shortcut can be judged.

**Caveats.** 1989 thesis; GPU texture hardware has since standardised
trilinear and anisotropic approximations that trade accuracy for speed. The
local PDF is a scan without a text layer, so searching it needs OCR.

### Smith 1995 — A pixel is not a little square (Technical Memo 6)

| Field        | Value                                                                                          |
| ------------ | ---------------------------------------------------------------------------------------------- |
| Authors      | Alvy Ray Smith                                                                                 |
| Venue/Year   | Microsoft Technical Memo 6, July 17, 1995                                                      |
| DOI or arXiv | none ([author's site][smith6])                                                                 |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/smith1995-pixel-is-not-a-little-square.pdf` |
| Open access  | Y (author's site)                                                                              |

**Claim.** A pixel is a point sample of a continuous image, not a little
geometric square; treating it as a square conflates the sample with the
reconstruction filter and leads to wrong resampling and compositing
arithmetic. The memo proposes a discrete-to-continuous mapping that fixes
where samples sit relative to continuous coordinates.

**Verbatim quote** (p. 1, abstract):

> The little square model is simply incorrect. It harms. It gets in the way.

**Relevance to sparkles.** The image abstraction should define, once, the
continuous coordinate of sample `(i, j)` (centre at `i + 0.5` or at `i`) and
every kernel, warp and GPU sampler path must use the same convention — the
classic half-pixel shift between CPU and GPU scalers is exactly this ambiguity.

**Caveats.** An essay, not a measurement; the little-square model remains
legitimate for some coverage computations, which the memo acknowledges.

### Nehab and Hoppe 2014 — A fresh look at generalized sampling

| Field        | Value                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------- |
| Authors      | Diego Nehab, Hugues Hoppe                                                                               |
| Venue/Year   | Foundations and Trends in Computer Graphics and Vision 8(1), pp. 1–84 (vol. dated 2012, published 2014) |
| DOI or arXiv | [10.1561/0600000053][nehab]                                                                             |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/nehab2014-fresh-look-generalized-sampling.pdf`       |
| Open access  | Y (author's site)                                                                                       |

**Claim.** Brings the signal-processing "generalized sampling" framework to
graphics: a reconstruction or analysis filter can be factored into a short
compactly supported kernel (e.g. a B-spline) plus a digital recursive filter
applied to the samples. That factorisation gives sharper, higher-quality
reconstruction (cardinal cubic B-splines, O-MOMS) at roughly the cost of a
short kernel, and improves prefiltering for downscaling.

**Verbatim quote** (p. 4, abstract):

> Major advances in signal-processing research have shown that these operations can often be performed more efficiently by decomposing a filter into two parts: a compactly supported continuous-domain function and a digital filter.

**Relevance to sparkles.** Argues for a two-stage resampler: an in-place
recursive prefilter pass (cheap, causal/anti-causal, SIMD across rows) and a
short-support evaluation pass that maps directly onto GPU bilinear-fetch
tricks. The design should keep the prefilter optional and the kernel generic.

**Caveats.** Recursive filters are sequential along a row (parallelise across
rows/columns or use block-parallel formulations); boundary handling of the
infinite-impulse prefilter needs care.

### Porter and Duff 1984 — Compositing digital images

| Field        | Value                                                                                         |
| ------------ | --------------------------------------------------------------------------------------------- |
| Authors      | Thomas Porter, Tom Duff                                                                       |
| Venue/Year   | SIGGRAPH '84 / Computer Graphics 18(3), pp. 253–259, 1984                                     |
| DOI or arXiv | [10.1145/800031.808606][porter]                                                               |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/porter1984-compositing-digital-images.pdf` |
| Open access  | Y (Pixar Graphics Library, via web.archive.org)                                               |

**Claim.** Introduces the RGBA pixel with colour stored premultiplied by alpha
and enumerates the twelve binary compositing operators (`over`, `in`, `out`,
`atop`, `xor`, …) under an uncorrelated-coverage assumption, plus unary
operators. Premultiplied storage keeps outputs premultiplied and makes the
algebra closed.

**Verbatim quote** (p. 2):

> Storage of the color components premultiplied by the alpha would seem to unduly quantize the color resolution, especially as alpha approaches 0. However, because any compositing of the picture will require that multiplication anyway, storage of the product forces only a very minor loss of precision in this regard.

**Relevance to sparkles.** Alpha representation must be a type-level property
(`Premultiplied` vs `Straight`) so that `over` cannot be applied to straight
alpha by accident, and so resampling (which must run on premultiplied values)
can require it. PNG/WebP decode straight alpha; the converter belongs at the
codec boundary.

**Caveats.** The uncorrelated-coverage assumption fails for coincident edges
(conflation artifacts); the precision note assumes float or wide integers, and
8-bit premultiplied storage does lose colour at low alpha.

### Smith 1995 — Image compositing fundamentals (Technical Memo 4)

| Field        | Value                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------------ |
| Authors      | Alvy Ray Smith                                                                                   |
| Venue/Year   | Microsoft Technical Memo 4, August 15, 1995                                                      |
| DOI or arXiv | none ([author's site][smith4])                                                                   |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/smith1995-image-compositing-fundamentals.pdf` |
| Open access  | Y (author's site)                                                                                |

**Claim.** Contrasts premultiplied and non-premultiplied alpha and shows the
premultiplied form needs fewer multiplies and gives simpler formulas, and that
the non-premultiplied form is not closed under `over` as usually defined.
Premultiplied alpha leads naturally to the "sprite" (shaped image) concept.

**Verbatim quote** (p. 1, abstract):

> We shall show that the non-premultiplied alpha formulation is not closed on over, the fundamental image compositing operator—as usually defined.

**Relevance to sparkles.** Supports making premultiplied the internal default
for every composite and filter kernel, with straight alpha only as an I/O
format. It also gives the 8-bit integer tricks (`a*b/255` with rounding) that
a SIMD `over` needs.

**Caveats.** Short tutorial memo; the closure argument is about `over`, not
about filtering, and it says nothing about linear-light vs encoded values,
which matters as much as premultiplication for correct blending.

### Poynton 1997 — Frequently asked questions about color

| Field        | Value                                                                         |
| ------------ | ----------------------------------------------------------------------------- |
| Authors      | Charles Poynton                                                               |
| Venue/Year   | Self-published FAQ, revision 1997-03-02a                                      |
| DOI or arXiv | none ([author's site][poynton])                                               |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/poynton1997-color-faq.pdf` |
| Open access  | Y (author's site, via web.archive.org)                                        |

**Claim.** A compact primer on intensity, luminance, lightness, tristimulus
values, chromaticity and the colour-coding systems used in video and
graphics. It insists on distinguishing linear-light components from
gamma-corrected ones, and luminance `Y` from video luma `Y'`, and explains
`3×3` primaries conversion as a linear-light operation.

**Verbatim quote** (p. 6):

> First a nonlinear transfer function – gamma correction – is applied to each of the linear R, G and B. Then a weighted sum of the nonlinear components is computed to form a signal representative of luminance. The resulting component is related to brightness but is not CIE luminance.

**Relevance to sparkles.** Primes belong in type names: a `Rgb!(Linear)` and
an `Rgb!(Encoded!Srgb)` must be different types, and `Y'CbCr` decode must not
be documented as producing luminance. Matrix conversion between primaries
should be defined on linear values with the encoded-domain shortcut allowed
only where its error is shown to be negligible.

**Caveats.** CRT-era and pre-HDR; coefficients cite Rec. 601/709 only. Poynton's
later books supersede it; use it for vocabulary and cite the standards for
numbers.

### Sharma, Wu and Dalal 2005 — The CIEDE2000 color-difference formula: implementation notes

| Field        | Value                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------- |
| Authors      | Gaurav Sharma, Wencheng Wu, Edul N. Dalal                                                         |
| Venue/Year   | Color Research and Application 30(1), pp. 21–30, 2005                                             |
| DOI or arXiv | [10.1002/col.20070][sharma]                                                                       |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/sharma2005-ciede2000-implementation-notes.pdf` |
| Open access  | Y (author's site)                                                                                 |

**Claim.** Gives a step-by-step statement of CIEDE2000, lists implementation
errors (hue-angle wrap, mean-hue computation) that the original CIE test data
does not catch, and publishes a larger test set. It also shows the formula has
small mathematical discontinuities in hue.

**Verbatim quote** (p. 1, abstract):

> We indicate several potential implementation errors that are not uncovered in tests performed using the original sample data published with the standard.

**Relevance to sparkles.** Ready-made oracle: the supplementary data set is the
test vector table for a `deltaE2000` function, and the paper is the model for
how `sparkles` colour code should be tested — published vectors plus the
edge cases where naive implementations diverge.

**Caveats.** CIEDE2000 is a small-difference SDR metric on CIELAB; it is not
calibrated for HDR or wide-gamut differences (see Jzazbz).

### Li et al. 2017 — Comprehensive color solutions: CAM16, CAT16, and CAM16-UCS

| Field        | Value                                                                                                                            |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Changjun Li, Zhiqiang Li, Zhifeng Wang, Yang Xu, Ming Ronnier Luo, Guihua Cui, Manuel Melgosa, Michael H. Brill, Michael Pointer |
| Venue/Year   | Color Research and Application 42(6), pp. 703–718, 2017                                                                          |
| DOI or arXiv | [10.1002/col.22131][li]                                                                                                          |
| Local PDF    | no open PDF                                                                                                                      |
| Open access  | N                                                                                                                                |

**Claim.** Restructures CIECAM02 so that chromatic and luminance adaptation
happen in one space, fixing the computational failures it shows in certain
cases (e.g. cross-media colour reproduction) without losing predictive
accuracy. Proposes
CAT16 as the chromatic adaptation transform and CAM16-UCS as the uniform
colour space.

**Verbatim quote** (abstract, Crossref metadata record):

> However, it has been found that computational failures can occur in certain cases such as during the image processing of cross‐media color reproduction applications.

**Relevance to sparkles.** If `sparkles:image` ships an appearance model it
should be CAM16 rather than CIECAM02, and its domain must be explicit:
every input must map to a finite output (a total function) or be rejected —
the CIECAM02 failures are exactly the kind of numeric hostile-input bug a
`@safe pure nothrow` colour kernel must not have.

**Caveats.** Only the abstract was read. Viewing-condition parameters make it
heavy for per-pixel use; Oklab (below) trades accuracy for a cheap fixed
pipeline. The CIE later standardised the model with modifications as CIECAM16
(CIE 248:2022), so an implementation must say which of the two it follows.
Even CAM16 keeps edge-case breakdowns, which Schlömer (below) catalogues.

### Schlömer 2018 — Algorithmic improvements for the CIECAM02 and CAM16 color appearance models

| Field        | Value                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------------ |
| Authors      | Nico Schlömer                                                                                    |
| Venue/Year   | arXiv preprint, eess.IV, February 2018 (local copy v2, October 14, 2021)                         |
| DOI or arXiv | [arXiv:1802.06067][schlomer]                                                                     |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/schlomer2018-ciecam02-cam16-improvements.pdf` |
| Open access  | Y (arXiv)                                                                                        |

**Claim.** Walks through the CAM16 (and, identically, CIECAM02) steps and fixes
the ones that misbehave on edge inputs. The forward model's `+0.1` term in the
post-adaptation cone response cancels algebraically but not in floating point,
so `X = Y = Z = 0` yields small non-zero correlates (saturation `s ≈ 1.1e-5`
where the exact answer is 0); the note confines the term to the one step that
needs it. The saturation formula `s = 100·√(M/Q)` divides by zero at black and
is rewritten into an always-defined form. In the inverse model, the case split
on `t = 0` and on `|sin h|` vs `|cos h|` that guards against division by zero
is replaced by one expression whose denominator is provably positive. Four
linear combinations become one matrix–vector product. The result is
algebraically equivalent to the published model; the inverse runs about 5%
faster in the author's `colorio` implementation.

**Verbatim quote** (p. 2):

> Unfortunately, said cancellation is not always exact when computed in floating point arithmetic. Luckily, the adverse effect of such rounding errors is rather limited here.

**Relevance to sparkles.** A colour appearance kernel meets black, greys and
slightly negative tristimulus values from matrix round-off on every real
image, so a D implementation should adopt these formulations rather than
transcribe the CIE pseudocode. Its tests should check two separate
properties: agreement with the standard's worked values, and exact results
(no `NaN`, no residue) at `X = Y = Z = 0` and along the achromatic axis, with
forward/inverse round-trips property-tested over the whole input cube. The
matrix–vector form is one `4×3` product, a single SIMD or shader matrix multiply.

**Caveats.** A short preprint, not peer reviewed. The 5% speed-up is measured
on the author's `colorio` package and does not transfer quantitatively to D
or shaders; the reformulations are claimed equivalent, so outputs should match
the published model to rounding except where the original misbehaves.

### Safdar et al. 2017 — Perceptually uniform color space for image signals including HDR and wide gamut (Jzazbz)

| Field        | Value                                                         |
| ------------ | ------------------------------------------------------------- |
| Authors      | Muhammad Safdar, Guihua Cui, Youn Jin Kim, Ming Ronnier Luo   |
| Venue/Year   | Optics Express 25(13), p. 15131, 2017                         |
| DOI or arXiv | [10.1364/OE.25.015131][safdar]                                |
| Local PDF    | no open PDF (free to read at the publisher; not held locally) |
| Open access  | Y (Optica open-access licence)                                |

**Claim.** Proposes `Jzazbz`, a uniform colour space for HDR and wide-gamut
signals built on a PQ-like nonlinearity, aiming at uniformity, hue linearity,
small- and large-difference prediction and low computational cost; evaluated
against several data sets in comparison with CIELAB, CAM16-UCS, ICtCp and
others.

**Verbatim quote** (abstract, Semantic Scholar API record):

> Such a space would be perceptually uniform over a wide gamut, linear in iso-hue directions, and can predict both small and large color differences as well as lightness in high dynamic range environments.

**Relevance to sparkles.** A candidate working space for HDR gamut mapping and
HDR-aware difference metrics in tests (a `deltaEz` beside `deltaE2000`). It
takes absolute luminance, so the image type must know whether a buffer is
display-referred in nits (PQ) or relative (HLG/SDR). Its PQ-based nonlinearity
can reuse the same tested PQ kernel as signal decoding.

**Caveats.** Fitted to specific data sets; only the abstract was read (the
full text is free at the DOI but is not held locally).

### Ottosson 2020 — A perceptual color space for image processing (Oklab)

| Field        | Value                                                                           |
| ------------ | ------------------------------------------------------------------------------- |
| Authors      | Björn Ottosson                                                                  |
| Venue/Year   | Blog post, December 2020 (matrices updated 2021-01-25; introduction added 2025) |
| DOI or arXiv | none ([web source][oklab])                                                      |
| Local PDF    | web source                                                                      |
| Open access  | Y                                                                               |

**Claim.** Defines Oklab: an opponent space with IPT's computational
structure (matrix, cube root, matrix) fitted to data generated with CAM16 so
that lightness, chroma and hue are predicted well, blending is even, and
scale changes only scale the coordinates. Reference code is public domain and
the space is now in CSS Color 4.

**Verbatim quote** (web page):

> For this reason it is reasonable to try to make a new color space, with the same computational structure as IPT, but that performs closer to CAM16-UCS in terms of predicting lightness and chroma. This exploration resulted in Oklab.

**Relevance to sparkles.** Two `3×3` matrices and a cube root vectorise
trivially and run in a shader, which makes Oklab the practical default for
gradients, perceptual blends and saturation edits; it should be a named colour
space in the type vocabulary next to CIELAB.

**Caveats.** Not peer reviewed; fitted to synthetic CAM16 data and assumes
D65 and normal viewing; not designed for HDR absolute luminance.

### Miller, Nezamabadi and Daly 2013 — Perceptual signal coding for more efficient usage of bit codes (PQ)

| Field        | Value                                                                                                                                           |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Scott Miller, Mahdi Nezamabadi, Scott Daly                                                                                                      |
| Venue/Year   | SMPTE Motion Imaging Journal 122(4), pp. 52–59, May 2013; conference version: SMPTE 2012 Annual Technical Conference & Exhibition, October 2012 |
| DOI or arXiv | [10.5594/J18290][miller] (journal); [10.5594/M001446][miller-conf] (conference)                                                                 |
| Local PDF    | no open PDF                                                                                                                                     |
| Open access  | N                                                                                                                                               |

**Claim.** Derives the perceptual quantizer (PQ) EOTF from Barten's contrast
sensitivity model so that each code value step stays near the visibility
threshold over 0–10 000 cd/m², allowing 10–12-bit absolute-luminance HDR
signals. PQ was standardised as SMPTE ST 2084 and in BT.2100.

**Verbatim quote:** none — no open full text or abstract was available to
quote from (the publisher elides the abstract from public metadata).

**Relevance to sparkles.** The PQ formula and constants are normative in
BT.2100 (below), so the implementation should cite and test against BT.2100;
this paper explains why the curve is shaped as it is and why PQ values are
absolute nits rather than relative.

**Caveats.** Paywalled; Dolby origin (check the standard's patent
declarations before assuming royalty-free use — the formula itself is
published in ITU and SMPTE documents).

### Borer and Cotton 2015 — A "display independent" high dynamic range television system (HLG)

| Field        | Value                                                                                        |
| ------------ | -------------------------------------------------------------------------------------------- |
| Authors      | Tim Borer, Andrew Cotton                                                                     |
| Venue/Year   | IBC 2015 conference; BBC R&D White Paper WHP 309, September 2015                             |
| DOI or arXiv | [10.1049/ibc.2015.0005][borer]                                                               |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/borer2015-display-independent-hdr-tv.pdf` |
| Open access  | Y ([BBC R&D white paper][whp309])                                                            |

**Claim.** Presents Hybrid Log-Gamma: a relative, scene-referred OETF whose
lower part follows a conventional gamma curve and upper part a logarithm, so
one signal displays acceptably on SDR screens and scales to HDR displays of
any peak luminance via a display-dependent system gamma. Banding is analysed
and shown comparable to competing schemes.

**Verbatim quote** (p. 3, abstract):

> it also delivers a high quality “compatible” image to legacy standard dynamic range (SDR) screens and can be mixed, re-sized and compressed using standard tools and equipment.

**Relevance to sparkles.** HLG and PQ need different handling in the type
system: HLG is relative and needs a display-peak parameter at render time
(its OOTF), PQ is absolute. Resizing HLG in the encoded domain is presented as
tolerable — a claim to test, not to assume, in the resampler.

**Caveats.** Advocacy paper from the scheme's authors; the BBC copyright
notice restricts redistribution of the PDF (keep local, link to the BBC page).

### ITU-R BT.2100-3 (2025) — Image parameter values for HDR television

| Field        | Value                                                                         |
| ------------ | ----------------------------------------------------------------------------- |
| Authors      | ITU-R Study Group 6                                                           |
| Venue/Year   | Recommendation ITU-R BT.2100-3, February 2025                                 |
| DOI or arXiv | none ([ITU publication][bt2100])                                              |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/itu2025-bt2100-hdr-tv.pdf` |
| Open access  | Y (ITU free download)                                                         |

**Claim.** Normative definitions of BT.2020 primaries for HDR, the PQ and HLG
EOTF/OETF/OOTF pairs with exact constants, the `Y'CbCr`, constant-luminance
and `ICtCp` signal formats, and narrow/full-range integer coding.

**Verbatim quote** (p. 4):

> that for programme production and international exchange of HDR-TV, the Perceptual Quantization (PQ) or Hybrid Log-Gamma (HLG) specifications described in this Recommendation should be used.

**Relevance to sparkles.** The source of truth for transfer-function
constants (`m1 = 2610/16384`, …) and range scaling. Each function should be
implemented once, generic over float width, with tests that its inverse
round-trips and that integer code values match the standard's tables.

**Caveats.** Revised three times since 2016; cite the revision implemented.

### ITU-R BT.2390-12 (2025) — High dynamic range television for production and international programme exchange

| Field        | Value                                                                             |
| ------------ | --------------------------------------------------------------------------------- |
| Authors      | ITU-R Study Group 6                                                               |
| Venue/Year   | Report ITU-R BT.2390-12, March 2025                                               |
| DOI or arXiv | none ([ITU publication][bt2390])                                                  |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/itu2025-bt2390-hdr-report.pdf` |
| Open access  | Y (ITU free download)                                                             |

**Claim.** The explanatory companion to BT.2100: design rationale for the PQ
and HLG non-linearities, the relationship between OETF, EOTF and OOTF
(rendering intent), black and white level determination, HLG's SDR
compatibility, and the `Y'CbCr` and `ICtCp` colour representations. This
revision defers display mapping for displays that cannot reach the reference
range to Reports ITU-R BT.2408 and BT.2446.

**Verbatim quote** (p. 28):

> Simply applying a gamma curve to each component separately as is done for SDR television distorts the colour; in particular, it distorts saturation but also to a lesser extent the hue.

**Relevance to sparkles.** Tone mapping and OOTFs must operate on luminance
(or a luminance-like channel) and rescale RGB, not apply per-channel curves.
A concrete HDR→SDR display-mapping default for `hue` and gain-map rendering
has to come from the reports this one points to (BT.2408, BT.2446), not from
BT.2390 itself.

**Caveats.** Informative, not normative; long and revised frequently.

### ITU-R BT.2407-0 (2017) — Colour gamut conversion from BT.2020 to BT.709

| Field        | Value                                                                                   |
| ------------ | --------------------------------------------------------------------------------------- |
| Authors      | ITU-R Study Group 6                                                                     |
| Venue/Year   | Report ITU-R BT.2407-0, October 2017                                                    |
| DOI or arXiv | none ([ITU publication][bt2407])                                                        |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/itu2017-bt2407-gamut-conversion.pdf` |
| Open access  | Y (ITU free download)                                                                   |

**Claim.** States the requirements for wide-to-narrow gamut conversion
(in-gamut colours unchanged, minimal hue change, no loss of detail, no
discontinuities, mathematically definable), shows that a matrix plus hard
clip violates them, and describes several gamut-mapping methods
(e.g. lightness/hue/chroma mapping in a perceptual space).

**Verbatim quote** (p. 3):

> There is no universal gamut mapping method which can achieve all of these requirements simultaneously. In converting from a wider colour gamut to a smaller colour gamut, modification of colours outside the BT.709 gamut is unavoidable.

**Relevance to sparkles.** Gamut conversion needs a pluggable `GamutMapper`
policy (clip, perceptual compress-in-Oklab/Jzazbz, …) rather than one fixed
function, and the requirement list is a ready test specification for each
policy.

**Caveats.** Broadcast-centric; also omits metrics, as it says itself. For
the wider gamut-mapping literature, Morovič and Luo's 2001 JIST survey (DOI
10.2352/J.ImagingSci.Technol.2001.45.3.art00013) has no open PDF, so it is
not an entry here.

### ICC.1:2022 — Image technology colour management: architecture, profile format, and data structure

| Field        | Value                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------ |
| Authors      | International Color Consortium                                                             |
| Venue/Year   | ICC.1:2022 (profile version 4.4.0.0), 2022; update of ICC.1:2010 = ISO 15076-1:2010        |
| DOI or arXiv | none ([ICC specification][icc1])                                                           |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/icc2022-icc1-profile-specification.pdf` |
| Open access  | Y (ICC free download)                                                                      |

**Claim.** Specifies the v4 ICC profile: the D50 profile connection space
(PCS), the four rendering intents, the tagged binary file format, the profile
classes (input, display, output, device link, colour space, abstract, named
colour), and the tag types (curves, `lutAtoBType`, matrices, parametric curves)
that a CMM evaluates.

**Verbatim quote** (p. 8):

> The colour rendering of the perceptual and saturation rendering intents is vendor specific.

**Relevance to sparkles.** Two consequences. First, an ICC profile is a
complex tagged binary format embedded in every JPEG/PNG/TIFF/AVIF — a prime
hostile-input surface that belongs on `wired`'s checked-view parser with
offset/size bounds and LUT-size budgets. Second, only the colorimetric
intents are reproducible across CMMs; tests can compare against a reference
CMM only for those.

**Caveats.** Large. Real-world profiles include v2 files, malformed tag tables
and vendor private tags the specification does not cover, so strict
rejection alone is not a viable product policy. Because the perceptual intent
leaves gamut mapping to the profile creator, two conforming implementations
can still disagree visually.

### ICC.2:2023 — Extensions to architecture, profile format, and data structure (iccMAX)

| Field        | Value                                                                                     |
| ------------ | ----------------------------------------------------------------------------------------- |
| Authors      | International Color Consortium                                                            |
| Venue/Year   | ICC.2:2023 (iccMAX), 2023; with the ICC approval ballot prepended                         |
| DOI or arXiv | none ([ICC specification][icc2])                                                          |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/icc2023-icc2-iccmax-specification.pdf` |
| Open access  | Y (ICC free download)                                                                     |

**Claim.** Extends ICC.1 with arbitrary illuminants and observers, spectral
PCSs, an extended-range HDR colorimetric PCS, and a programmable calculator
element for transforms; conformance is defined per workflow domain rather
than as the whole specification.

**Verbatim quote** (p. 15):

> As such, it is not envisioned that all colour management systems that use this document will implement all the features or capabilities specified by this document.

**Relevance to sparkles.** Out of scope for a first implementation, but the
parser must recognise iccMAX profiles (version 5) and report them rather than
misreading them as v4: recognise, report, and either reject or hand them to an
explicit opt-in path, never interpret them silently on the decode path. The
calculator element is a small interpreter inside an image decoder, so any
future support needs an operation budget.

**Caveats.** Little deployed in consumer image files today; the local PDF
opens with ballot boilerplate before the specification body.

### ITU-T H.273 (V4, 2024) — Coding-independent code points for video signal type identification (CICP)

| Field        | Value                                                                                          |
| ------------ | ---------------------------------------------------------------------------------------------- |
| Authors      | ITU-T Study Group 16 (twin text of ISO/IEC 23091-2)                                            |
| Venue/Year   | Recommendation ITU-T H.273 (V4), July 2024                                                     |
| DOI or arXiv | none ([ITU publication][h273])                                                                 |
| Local PDF    | `~/code/repos/papers/image-video/resampling-colour/itu2024-coding-independent-code-points.pdf` |
| Open access  | Y (ITU free download)                                                                          |

**Claim.** Defines the integer code points shared by H.264/HEVC/AV1/VVC,
AVIF/HEIF and PNG `cICP`: `ColourPrimaries`, `TransferCharacteristics`,
`MatrixCoefficients`, `VideoFullRangeFlag`, chroma sample location and frame
packing, with the formulas each code point denotes.

**Verbatim quote** (p. 10):

> unspecified: Values of a particular code point that has no specified meaning in the version of this Specification and will not have a specified meaning as an integral part in any future versions of this Specification.

**Relevance to sparkles.** CICP should be the canonical colour-signal
description inside `sparkles:image` (an enum per axis plus full-range flag),
with ICC as the fallback: each format front end maps its native signalling
into one CICP value. Parsers must treat "reserved" and "unspecified"
differently — reserved may gain meaning later, unspecified never will — and
map both to an explicit `unknown` instead of guessing BT.709. When a file
carries both CICP and an embedded ICC profile, which one wins is a per-format
rule (PNG and HEIF/AVIF each state their own) that belongs in one place.

**Caveats.** Code points identify a signal; they do not say how to tone-map
or gamut-map it.

### Google 2024 / ISO 21496-1:2025 — Ultra HDR image format v1.1 and gain-map metadata

| Field        | Value                                                                                  |
| ------------ | -------------------------------------------------------------------------------------- |
| Authors      | Google (Android media); ISO/TC 42 for ISO 21496-1                                      |
| Venue/Year   | Android developer documentation, last updated 2024-10-25; ISO 21496-1:2025 (July 2025) |
| DOI or arXiv | none ([Ultra HDR specification][ultrahdr]; [ISO 21496-1][iso21496])                    |
| Local PDF    | web source (ISO 21496-1 is paywalled: no open PDF)                                     |
| Open access  | Y (Ultra HDR); N (ISO 21496-1)                                                         |

**Claim.** Stores an SDR base JPEG plus a secondary gain-map image and
metadata (min/max content boost, gamma, offsets, HDR capacity range); an
HDR-capable renderer reconstructs HDR by applying the log-encoded gain,
weighted by the display's available headroom. v1.1 can additionally carry
ISO 21496-1 metadata in the same file.

**Verbatim quote** (web page):

> The recovery(x, y) function behavior where pixel_gain(x, y) is zero is implementation defined, because log2(0) is undefined.

The same page also says of a gain map whose resolution differs from the
primary image: "The filtering method must be bilinear or better and is
implementation defined."

**Relevance to sparkles.** Gain-map decode sits exactly at this thread's
crossroads: it needs a resampler (the map is usually lower resolution), a
linear-light multiply, and HDR metadata in the image type. A gain-map image is
best modelled as one paired-image value (base, gain map, metadata) with the
reconstruction stated once, not two pictures a caller combines by hand. The
"implementation defined" points must become documented, tested `sparkles`
choices, and metadata such as `max == min` must be validated so that no
division by zero or `log2(0)` reaches the kernel.

**Caveats.** Two overlapping metadata carriers (XMP `hdrgm` and ISO 21496-1)
that can disagree within one file; the ISO text was not consulted.

## Thread synthesis

**Consensus.** The sources agree that a pixel is a sample of a continuous
signal and that resampling is reconstruct–(warp)–prefilter–sample (Smith,
Heckbert, Turkowski, Nehab–Hoppe). Compositing and filtering are correct on
premultiplied values (Porter–Duff, Smith). Colour arithmetic that models light
(blending, scaling, primaries conversion, tone mapping) happens on linear-light
values, while perceptual operations happen in a perceptual space, and the two
must not be confused (Poynton, BT.2390). HDR signals come in two incompatible
kinds — absolute PQ and relative HLG — with normative formulas in BT.2100.
Metadata, not pixel values, decides meaning: CICP code points, ICC profiles,
gain-map metadata. Colour-appearance formulas as published are not safe to
transcribe: CIECAM02 failed on some inputs (Li et al.), and CAM16 still
leaves rounding residue at black and an undefined saturation at `Q = 0` until
reformulated (Schlömer).

**Disagreements.** There is no best kernel: Keys optimises accuracy order,
Mitchell–Netravali perceived trade-offs, Turkowski frequency response at
integer ratios, Nehab–Hoppe approximation quality per cost. Perceptual spaces
trade accuracy for cost — CAM16 (accurate, heavy, viewing-condition aware),
Jzazbz (HDR absolute), Oklab (cheap, SDR-oriented). Gamut mapping has no
universal method (BT.2407), and ICC leaves perceptual intent vendor-specific.
The sources also place display adaptation in different stages: PQ leaves it to
display-side mapping of an absolute signal (which BT.2390 defers to BT.2408
and BT.2446), HLG builds it into the system OOTF, gain maps parameterise it by
display headroom at render time, and ICC bakes it into per-intent profile
transforms; none defines what happens when these are stacked. Finally, the HLG
paper claims encoded-domain processing is acceptable; the linear-light camp
says otherwise for resampling.

**Open problems.** Resampling HDR content without ringing overshoot into
negative or above-peak values; agreed gain-map reconstruction when the two
metadata carriers disagree; a perceptual space that is both cheap and valid
for HDR; deterministic CPU/GPU parity for transcendental transfer functions
(`pow`, `log2`) across drivers. No source here treats colour metadata as an
attack surface: bounds-checked ICC parsing, overflow-safe LUT sizing, and
limits on profile- and gain-map-driven computation are obligations this thread
implies but does not discharge.

**What a D implementation should take from this:**

- Put signal semantics in the type: transfer function (linear, sRGB, PQ,
  HLG, …), primaries, alpha mode (`Premultiplied`/`Straight`), range, and
  sample-position convention; let algorithms constrain on them with template
  constraints instead of runtime checks.
- Make kernels values, not names: one `(B, C)` cubic, Lanczos-`n`, box and
  tent, each with support, phase and compile-time weight tables, consumed by
  one separable resampler that has SIMD and `sparkles:shaders` back ends.
- Define edge handling and the pixel-centre convention once (Smith) and test
  CPU/GPU agreement against it.
- Implement transfer functions from BT.2100/H.273 formulas, generic over float
  width, with round-trip and code-value tests; gate fast approximations behind
  measured error bounds.
- Treat ICC profiles and CICP/gain-map metadata as hostile input: parse with
  bounded checked views (`wired`), cap LUT sizes and calculator operations,
  map reserved/unspecified code points to `unknown`, keep iccMAX behind an
  opt-in, and reject degenerate metadata.
- Offer gamut mapping and tone mapping as policies (clip, a BT.2408
  display-mapping curve, perceptual compression in Oklab/Jzazbz) rather than
  one baked-in choice.
- If an appearance model is shipped, implement CAM16 in Schlömer's
  reformulation, state whether it follows CAM16 or CIECAM16, and property-test
  it for finite, exact output at black and along the grey axis.
- Ship published test vectors (CIEDE2000 data, BT.2100 constants) as
  `@safe pure nothrow @nogc` unittests.

## Sources

- [Keys 1981][keys]: DOI record; no local copy (the copies found carry an
  IEEE Xplore institutional licence stamp).
- [Mitchell and Netravali 1988][mitchell]: DOI record; local copy is a scan
  with a text layer (a second scan sits beside it with an `-alt` suffix).
- [Turkowski 1990][turkowski]: DOI record for the Graphics Gems chapter; local
  copy is the author's 10 April 1990 preprint.
- [Heckbert 1989][heckbert]: Berkeley EECS technical report; local copy is a
  scan without a text layer (quote read by OCR).
- [Smith, Memo 6][smith6] and [Smith, Memo 4][smith4]: author-hosted PDFs.
- [Nehab and Hoppe 2014][nehab]: DOI record; local copy from the authors.
- [Porter and Duff 1984][porter]: DOI record; local copy from the archived
  Pixar Graphics Library.
- [Poynton, Color FAQ][poynton]: author PDF, revision 1997-03-02a.
- [Sharma et al. 2005][sharma]: DOI record; local copy from the first author's
  site.
- [Li et al. 2017][li] and [Safdar et al. 2017][safdar]: DOI records; quotes
  from the abstract records only.
- [Schlömer 2018][schlomer]: arXiv record (submitted 2018-02-16, v2
  2021-10-14).
- [Ottosson, Oklab][oklab]: web page.
- [Miller et al. 2013][miller] and its [2012 conference version][miller-conf]:
  DOI records; no open full text.
- [Borer and Cotton 2015][borer]: DOI record for the IBC paper; local copy is
  [BBC R&D White Paper WHP 309][whp309].
- [BT.2100][bt2100], [BT.2390][bt2390], [BT.2407][bt2407], [H.273][h273]: ITU
  free downloads.
- [ICC.1:2022][icc1] and [ICC.2:2023][icc2]: ICC free downloads.
- [Ultra HDR v1.1][ultrahdr]: web page; [ISO 21496-1][iso21496]: catalogue
  record only.

<!-- References -->

[keys]: https://doi.org/10.1109/TASSP.1981.1163711
[mitchell]: https://doi.org/10.1145/54852.378514
[turkowski]: https://doi.org/10.1016/B978-0-08-050753-8.50042-5
[heckbert]: https://www2.eecs.berkeley.edu/Pubs/TechRpts/1989/CSD-89-516.pdf
[smith6]: http://alvyray.com/Memos/CG/Microsoft/6_pixel.pdf
[nehab]: https://doi.org/10.1561/0600000053
[porter]: https://doi.org/10.1145/800031.808606
[smith4]: http://alvyray.com/Memos/CG/Microsoft/4_comp.pdf
[poynton]: https://web.archive.org/web/20260211200335/https://poynton.ca/PDFs/ColorFAQ.pdf
[sharma]: https://doi.org/10.1002/col.20070
[li]: https://doi.org/10.1002/col.22131
[schlomer]: https://arxiv.org/abs/1802.06067
[safdar]: https://doi.org/10.1364/OE.25.015131
[oklab]: https://bottosson.github.io/posts/oklab/
[miller]: https://doi.org/10.5594/J18290
[miller-conf]: https://doi.org/10.5594/M001446
[borer]: https://doi.org/10.1049/ibc.2015.0005
[whp309]: https://downloads.bbc.co.uk/rd/pubs/whp/whp-pdf-files/WHP309.pdf
[bt2100]: https://www.itu.int/rec/R-REC-BT.2100
[bt2390]: https://www.itu.int/pub/R-REP-BT.2390
[bt2407]: https://www.itu.int/pub/R-REP-BT.2407
[icc1]: https://www.color.org/specification/ICC.1-2022-05.pdf
[icc2]: https://www.color.org/specification/ICC.2-2023.pdf
[h273]: https://www.itu.int/rec/T-REC-H.273
[ultrahdr]: https://developer.android.com/media/platform/hdr-image-format
[iso21496]: https://www.iso.org/standard/86775.html
