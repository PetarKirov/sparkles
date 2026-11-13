# color (D)

Manu Evans' colour-type library for D: one `RGB` template parameterised by a component string, a component type, a linear flag and a named colour space, a family of CIE and cylindrical types that convert to one another through a compile-time parent graph, a bit-level `PackedRGB` type and a `NormalizedInt` component type, all proposed for Phobos as `std.experimental.color` and never merged.

| Field         | Value                                                                                                                                                |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | D (DMD front end, 2015 to 2020 dialect; builds unchanged with DMD 2.112.1 and LDC 1.43.0)                                                            |
| License       | Boost Software License 1.0 ([`dub.json`][dub-json])                                                                                                  |
| Repository    | [TurkeyMan/color][repo]; Phobos proposal [dlang/phobos#2845][pr2845]; registry package [`color` on code.dlang.org][dub-pkg]                          |
| Revision read | `e9d31e416b1718cd2983bf2c39a96814626227c3` (merge of PR #17, December 15, 2023; two commits after tag `v0.0.9`)                                      |
| Documentation | DDoc in the module headers ([`package.d`][pkg-head]); no rendered site at the pinned revision                                                        |
| Category      | D landscape: colour vocabulary (pixel element types, colour spaces, conversions)                                                                     |
| Size          | 8 modules, 4,128 lines (`colorspace.d` 431, `hsx.d` 454, `lab.d` 284, `package.d` 640, `packedrgb.d` 543, `rgb.d` 574, `xyz.d` 316, `normint.d` 886) |
| Tier          | A                                                                                                                                                    |
| Last reviewed | November 7, 2026                                                                                                                                     |

> [!NOTE]
> Claims marked **verified** were demonstrated by compiling and running scratch
> programs against an archive of the pinned tree (`git archive e9d31e41…`) with
> DMD 2.112.1 and LDC 1.43.0 from the repository's dev shell. Everything else is
> read from the source at the pinned revision or from the cited review threads.
> No performance claim in this page was measured.

---

## Overview

### What it solves

Every D image, game or multimedia library defines its own `struct Color { ubyte r, g, b, a; }`, and moving pixels between them means a hand-written adapter per pair. The library's stated aim is a shared vocabulary of colour _element_ types, precise enough about colour space that conversions between them can be generated rather than written. From the package header ([`package.d` L9-L14][pkg-intent]):

> "It is intended that this library facilitate a common API that allows a variety of image and multimedia libraries to interact more seamlessly, without need for constant conversions between custom, library-defined \_color data types. This package pays very careful attention to correctness with respect to \_color space definitions, and correct handling of \_color space conversions."

It covers single colour values only. Images are left to an external N-D slice: the header's example builds one with `std.experimental.ndslice` ([`package.d` L29-L51][pkg-ndslice]), a module that has since left Phobos for mir (it is absent from DMD 2.112.1's `std/experimental/`; **verified** by listing the installed import tree).

### Design philosophy

Three commitments recur in the source and the review thread:

1. **Everything is `@safe pure nothrow @nogc` and CTFE-able.** The header promises it for every type and function ([`package.d` L23-L26][pkg-nogc]): _"It is intended to be useful by realtime or memory-contrained systems such as video games, games consoles or mobile devices."_ Commit `02d3fab` (September 7, 2016) _"Converted colour space templates into functions, all can CTFE"_.
2. **Colour space is part of the type.** `RGB8` and `RGB!("rgb", ubyte, true)` are different types; the compiler, not a runtime tag, decides which conversion runs.
3. **Conversions are local; paths are derived.** Each type converts only to its declared `ParentColor`; `convertColor` finds a path through the parent graph at compile time. Evans in the review: _"direct conversions between unrelated color types are very rare. They almost always pipe through XYZ."_ ([PR comment, September 11, 2016][pr-xyz]).

The library is the canonical D data point in this catalog for _colour in the element type_. Compare it with [JuliaImages][juliaimages]' `ColorTypes` (the same idea with a type lattice) and Skia's `SkColorSpace` (colour as a runtime descriptor beside the pixels, due in wave 2 of the [master catalog][umbrella]).

---

## How it works

### The `RGB` template

The core declaration ([`rgb.d` L58-L74][rgb-template]):

```d
// std/experimental/color/rgb.d
struct RGB(string components_, ComponentType_, bool linear_ = false,
           RGBColorSpace colorSpace_ = RGBColorSpace.sRGB)
    if (isNumeric!ComponentType_)
```

- **`components_`** is a string over `r g b a l x`, in memory order. A string mixin emits one field per character, so `"bgra"` lays out B, G, R, A and `"rgbx"` adds a padding byte ([`rgb.d` L119-L127][rgb-fields]). Three `static assert`s reject unknown letters, an empty set, and `l` mixed with `rgb` ([`rgb.d` L92-L96][rgb-asserts]).
- **`ComponentType_`** is any numeric type. Floating types are stored as is; an integer `I` is wrapped as `NormalizedInt!I` ([`rgb.d` L98-L107][rgb-comptype]), so `ubyte` means "unsigned normalised 8-bit", never a raw integer.
- **`linear_`** says whether the stored values are linear light or transfer-encoded. It is a type flag, not a storage change: `RGB!("rgb", ubyte, true)` stores 8 bits of linear light.
- **`colorSpace_`** names a row of a fixed table, `RGBColorSpace` ([`colorspace.d` L84-L133][cs-enum]).

The common aliases ([`package.d` L140-L171][pkg-aliases]) are `RGB8`, `RGBX8`, `RGBA8`, `BGR8`, `BGRX8`, `BGRA8`, `L8`, `A8`, `LA8`, `RGBf32`, `RGBAf32`, and the signed `UV8`/`UVW8` for normal maps. Sizes are exact (`RGB8` 3 bytes, `RGBA8` and `RGBX8` 4, `RGBAf32` 16; **verified**).

Per-component operators (`+ - *` between colours; `* / % ^^` by a scalar) are generated from string templates by `ComponentExpression` ([`package.d` L623-L640][pkg-compexpr]), with `#` standing for the operator and `_` for the component name. They apply to whatever the stored values are, so `RGB8 + RGB8` adds encoded sRGB values.

### Colour-space descriptors

`RGBColorSpaceDesc!F` ([`colorspace.d` L150-L175][cs-desc]) is the full description of an RGB space:

```d
// std/experimental/color/colorspace.d (DDoc comments replaced)
struct RGBColorSpaceDesc(F) if (isFloatingPoint!F)
{
    alias GammaFunc = F function(F v) pure nothrow @nogc @safe;
    string name;
    GammaFunc toGamma;   // linear -> encoded
    GammaFunc toLinear;  // encoded -> linear
    xyY!F white;
    xyY!F red;
    xyY!F green;
    xyY!F blue;
}
```

The 22 rows of `rgbColorSpaceDefs` ([`colorspace.d` L337-L364][cs-table]) cover sRGB and its 2.2 approximation, the BT.601 family (NTSC 1953, SMPTE-C, NTSC-J, PAL/SECAM), BT.709 (`HDTV`), BT.2020 (`UHDTV`), the Lindbloom set of working spaces (Adobe RGB, ProPhoto, Wide Gamut, Bruce, Beta, Best, DonRGB 4, Ekta Space PS5, …) and three DCI-P3 variants. White points are a `WhitePoint!F` enum of CIE illuminants A to F12 plus `DCI` ([`colorspace.d` L27-L78][cs-white]).

Transfer functions are of two kinds:

- a hybrid linear segment plus power law, `linearToHybridGamma!(a, b, s, e)` and its inverse ([`colorspace.d` L242-L296][cs-hybrid]), instantiated as `linearTosRGB`, `linearToRec601` (also used for BT.709) and `linearToRec2020` ([`colorspace.d` L298-L310][cs-tf-aliases]);
- a pure power law, `linearToGamma!(gamma)`, used for Adobe RGB (2.2), ProPhoto and Apple RGB (1.8) and the DCI-P3 Theater and D65 rows (2.6); the DCI-P3 Apple row uses the sRGB curve ([`colorspace.d` L312-L332][cs-gamma], [`colorspace.d` L361-L363][cs-table]).

`rgbToXyzMatrix` derives the RGB-to-XYZ matrix from the four chromaticities in the standard way (primaries as columns, scaled so that RGB white maps to the white point) and `xyzToRgbMatrix` inverts it ([`colorspace.d` L185-L218][cs-matrix]). Both run at compile time inside `enum` initialisers. `chromaticAdaptationMatrix` builds a von Kries-style adaptation between two white points with an XYZ-scaling, Bradford or von Kries cone matrix ([`colorspace.d` L220-L240][cs-cat]).

### The conversion graph

A type is a colour if it can reach `XYZ!float` ([`package.d` L111-L114][pkg-iscolor]):

```d
// std/experimental/color/package.d
enum isColor(T) = __traits(compiles, convertColor!(XYZ!float)(T.init));
```

Each type declares a `ParentColor` and `static convertColorImpl` overloads to and from it: `RGB` → `XYZ`, `xyY` → `XYZ`, `Lab` → `XYZ`, `LCh` → `Lab`, `HSx` → `RGB`, `PackedRGB` → `RGB`. `FindPath` walks parents from both ends to a common template and `ConversionPath` trims the source ([`package.d` L566-L601][pkg-path]). The path is a type tuple; the unittest that pins it shows `LCh!float` to `HSI!double` going through `Lab!float`, `XYZ!double` and `RGB!("rgb", double)` ([`package.d` L602-L621][pkg-path-test]). `convertColor` recurses along the tuple, asking first the source and then the target for a `convertColorImpl` ([`package.d` L327-L363][pkg-convert]). Every type's `opCast` forwards to `convertColor`, so `cast(Lab!float) RGB8(255, 0, 0)` is the user-facing spelling, and it folds at compile time (`53.237 78.281 62.148` from an `enum`; **verified**).

Precision is chosen per conversion by `WorkingType` ([`package.d` L542-L564][pkg-worktype]): the wider float of two float types; the float side when only one side is a float (`FloatTypeFor` the target when only the source is); `float` when both sides are integers of at most 16 bits; `double` for wider integer pairs.

### RGB to RGB

When both colour space and linearity match, `RGB` to `RGB` is a pure component-type cast. Otherwise it linearises, applies a 3×3 matrix, and re-encodes ([`rgb.d` L329-L376][rgb-rgb2rgb]):

```d
// std/experimental/color/rgb.d, convertColorImpl (RGB -> RGB), abridged
static if (From.colorSpace != To.colorSpace)
{
    enum toXYZ = rgbToXyzMatrix(From.colorSpaceDesc!WorkType);
    enum toRGB = xyzToRgbMatrix(To.colorSpaceDesc!WorkType);
    enum mat = multiply(toXYZ, toRGB);
    WorkType[3] v = multiply(mat, [r, g, b]);
```

`multiply(toXYZ, toRGB)` is the product `toXYZ · toRGB`, which applied to a column vector computes `toXYZ(toRGB(v))`, the reverse of the intended `toRGB(toXYZ(v))`. **Verified:** linear sRGB red `(1, 0, 0)` cast directly to linear Adobe RGB gives `(0.497765, -0.258085, -0.063284)`; the same value cast first to `XYZ!double` and then to Adobe RGB gives `(0.715119, 0, 0)`, which equals the product of the library's own matrices in the correct order. Linear sRGB red to `DCI_P3_D65` shows the same split: direct `(0.738, -0.060, -0.017)`, through XYZ `(0.822, 0.033, 0.017)`. The path through `XYZ` is correct; the shortcut is not, and no unittest exercises it (the cross-space tests in `rgb.d` cover only same-primaries cases, [`rgb.d` L377-L406][rgb-rgb2rgb-test]).

### Normalised integers

`NormalizedInt!I` ([`normint.d` L24-L32][ni-struct]) maps unsigned `[0, I.max]` to `[0, 1]` and signed `[-I.max, I.max]` to `[-1, 1]`, with `I.min` clamped to `-1`. Arithmetic saturates. The unittest is the clearest specification ([`normint.d` L237-L279][ni-example]):

```d
// std/experimental/normint.d
z *= y;    assert(z == 50);   // multiply is performed in normalized space
z *= y;    assert(z == 9);    // multiplication rounds *down*
```

`ubyte` and `ushort` multiplies use a reciprocal-multiply shortcut (`r * 0x1011 >> 20`, [`normint.d` L93-L106][ni-mul]); every other component type (the signed ones and the 32-bit ones) goes through `double`. Narrowing between widths drops low bits (`v >> (srcBits - destBits)`), and widening replicates the bit pattern so `0x37` becomes `0x3737` ([`normint.d` L457-L506][ni-convbits]). Float to integer rounds to nearest and clamps ([`normint.d` L353-L383][ni-float]).

### Packed formats

`PackedRGB!(format, ComponentType, colorSpace)` ([`packedrgb.d` L112-L125][pk-template]) parses a format string at compile time: `"rgb_5_6_5"`, `"rgba_10_10_10_2"`, `"rgba_s10_s10_s10_u2"`, `"rgba_f16_f16_f16_f16"`, `"rgb_f11_f11_f10"`, `"rgb_9_9_9_e5"` (the template's DDoc, [`packedrgb.d` L115-L121][pk-template], and the `isPackedRGB` unittest, [`packedrgb.d` L32-L42][pk-examples]). `ParseFormat` turns it into `ComponentInfo { offset, bits, type }` records, with types `Unsigned`, `Signed`, `Float`, `Mantissa` and `Exponent` ([`packedrgb.d` L45-L69][pk-info], [`packedrgb.d` L448-L522][pk-parse]). Bits are assigned from the least significant bit in string order, so `rgb_5_6_5` packs red into bits 0 to 4 (`RGB8(255, 128, 64)` packs to `0x441F`; **verified**), which is Vulkan's `B5G6R5` layout, not `R5G6B5`: Vulkan names packed components from the most significant bit down ([Vulkan specification, packed formats][vk-packed]), and [`VK_FORMAT_B5G6R5_UNORM_PACK16`][vk-formats] puts R in bits 0 to 4. Storage is a `Buffer!N` of the widest unsigned word that divides the size; a component may not straddle a word ([`packedrgb.d` L71-L110][pk-buffer]). The unpacked type is always `RGB!(components, T, false, colorSpace)`; there is no linear flag on `PackedRGB`.

### HSx, Lab, xyY

- `HSx!(HSxType, T, colorSpace)` covers HSV, HSL, HSI, HCY′, HWB and HCG over a named RGB space ([`hsx.d` L74-L100][hsx-type]); its parent is the _encoded_ `RGB` of that space ([`hsx.d` L195-L197][hsx-parent]). Integer hue spans the whole integer range, a choice Evans defended in review because _"60 degrees is an important angle, but 2^n/6 is always a loss of precision"_ ([PR comment, September 9, 2016][pr-hsx]).
- `Lab!(F, whitePoint)` and `LCh!(F, whitePoint)` are float-only and default to D50 ([`lab.d` L38-L48][lab-struct]). The CIE `f` uses the rounded constants `0.008856` and `7.787` ([`lab.d` L148-L192][lab-conv]).
- `XYZ!F` and `xyY!F` are float-only and carry no white point ([`xyz.d` L59-L74][xyz-struct]). `xyY` from black returns the D65 chromaticity ([`xyz.d` L284-L292][xyz-black]).

### Parsing

`colorFromString` accepts `#rgb`, `#argb`, `#rrggbb`, `#aarrggbb` (alpha first) and the 147 X11/SVG names of the `Colors` enum, case-insensitively, in a throwing and a `nothrow @nogc` overload ([`package.d` L371-L447][pkg-parse]). The `@nogc` overload was added after review on October 7, 2016 (commit `ebd9370`).

---

## Analysis

### 1. Pixel and memory model

The library models one element, not an image. An element is a plain struct whose field order is exactly the component string, so `BGRA8[]` is bit-compatible with a BGRA framebuffer and `RGBX8` with a 32-bit padded format. There are no planes, strides, sub-sampling or tiles; YCbCr and other planar video forms are absent (no type, no matrix, no range). `PackedRGB` covers sub-byte and shared-exponent layouts but only as single elements of at most 64 bits per word. Images are delegated to `ndslice`; at the pinned DCV revision (`c777e2aa9`) DCV does not import the library either (a grep of its tree for `std.experimental.color` finds nothing), so the image-plus-colour integration 9il proposed in review ([PR comment, December 31, 2016][pr-9il-plan]) did not happen.

### 2. Genericity mechanism

Three mechanisms:

- **Template parameters as colour semantics.** Layout, component type, encoding and space are all compile-time values, so constraints such as `if (isRGB!C)` and `static if (From.linear == false)` select code paths with no runtime branch.
- **String-driven code generation.** Fields, operators and packed bit maps come from string mixins (`Components`, `ComponentExpression`, `ParseFormat`). This keeps the struct definitions short but makes the generated API invisible to DDoc and to IDEs.
- **A static-member protocol for extension.** A third-party type joins the graph by declaring `ParentColor` and `static convertColorImpl` ([`package.d` L54-L94][pkg-custom]). Evans called this awkward because UFCS cannot supply the hook from outside the type's module: _"static member functions only works if you have the code... let's say a 3rd party lib introduces a colour type, and you'd like to make conversions functions so it integrates, but you can't because UFCS doesn't work"_ ([PR comment, September 9, 2016][pr-ufcs]).

The closed part is the colour space: `RGB` takes an `RGBColorSpace` _enum value_, and the descriptor is looked up in a fixed `__gshared immutable` table ([`rgb.d` L111-L114][rgb-csdesc], [`colorspace.d` L337][cs-table]). A user can build an `RGBColorSpaceDesc` and its matrices, but cannot instantiate `RGB` over it, so a new RGB space can join only as a new colour _type_, whatever the README's "custom colourspace" entry suggests.

### 3. Colour and metadata

The strongest dimension, and the one with the most findings.

- **Present:** chromaticities and white point per space; sRGB, BT.601/709 and BT.2020 transfer curves as parameterised hybrid functions; pure gammas; derived RGB↔XYZ matrices; CIE XYZ, xyY, Lab, LCh; luma from the space's Y row for linear values, and for encoded values from the BT.601 weights (NTSC and PAL rows), the BT.709 weights (`HDTV`) or, for every other space including sRGB, the space's Y row applied to the encoded values (`toGrayscale`, [`rgb.d` L490-L526][rgb-gray]); Bradford and von Kries adaptation matrices.
- **Absent:** PQ (SMPTE ST 2084) and HLG transfer functions, BT.1886 display gamma, any notion of reference white or nits, extended-range (scRGB) semantics, CICP code points, ICC profiles of any kind, YCbCr matrices and narrow-range quantisation, gamut mapping, and alpha mode. The only mention of ICC is the D50 comment ([`colorspace.d` L39-L40][cs-white]). Some of this exists on unmerged upstream branches, which this page did not build: `hlg_uhd` (BT.2100 HLG), `aces`, `flog` and `slog3` (March 2018), and `yuv` (a 388-line `yuv.d`, 2016 and 2020).
- **White points are not adapted.** `chromaticAdaptationMatrix` is never called by any conversion (a grep of the tree finds only its definition). `XYZ` has no white point, so an sRGB (D65) value converted to ProPhoto (D50) or to the default `Lab` (D50) arrives unadapted. **Verified:** linear sRGB white becomes ProPhoto `(0.968, 1.013, 1.320)` and `Lab(D50)` `(100, -2.394, -19.369)`; with a Bradford D65→D50 matrix applied by hand, ProPhoto white becomes `(1, 1, 1)`; with `Lab!(double, WhitePoint!double.D65)` the result is `(100, 0, 0)`.
- **`Lab` to `Lab` across white points does not compile.** The `static` conversion refers to `this`, `L`, `a` and `b` ([`lab.d` L133-L146][lab-lab]); because it is a template, the error appears only on instantiation. **Verified** with `__traits(compiles, …)`.
- **The BT.709 curve is the camera OETF.** `HDTV` and the BT.601 rows linearise with the inverse of the BT.709 OETF ([`colorspace.d` L303-L306][cs-tf-aliases]), the scene-referred camera curve: its parameters (`1.099`, `0.018`, `4.5`, `0.45`) are those of the [BT.709][itu-709] OETF, not the 2.4 power law of the [BT.1886][itu-1886] display EOTF that decoders use for display-referred output.
- **Alpha is unspecified and lossy.** `defaultAlpha` is zero, with the comment `// DEBATE: which should it be?` and the opaque alternative commented out ([`rgb.d` L48-L55][rgb-alpha]), so `RGBA8(1, 2, 3).a == 0` (**verified**). `RGB` to `XYZ` discards alpha, so `RGBA8` to `XYZ` to `RGBA8` turns opaque white transparent; the library's own unittest asserts this ([`package.d` L364-L368][pkg-convert]). Straight versus premultiplied is never stated.

### 4. I/O and codec architecture

Not applicable: no codec, no file format, no metadata parsing. The one parser is `colorFromString`, a bounded scan over a `const(char)[]` ([`package.d` L455-L540][pkg-parse-impl]). The relevance to Q4 is indirect: `PackedRGB` is a compile-time description of bit layouts, the same problem a format descriptor in `sparkles:wired` has to express for packed pixel words.

### 5. Hostile input and safety

The library sees no untrusted bytes except strings, and `colorFromStringImpl` checks lengths and characters before indexing. The hazards are numeric:

- `inverse` asserts a non-zero determinant ([`colorspace.d` L416-L419][cs-inverse]); the matrices are compile-time constants, so this can only fire for a degenerate user descriptor.
- `PackedRGB`'s float codec treats exponent 0 and the maximum exponent as ordinary values ([`packedrgb.d` L247-L267][pk-float-dec], [`packedrgb.d` L356-L379][pk-float-enc]). **Verified:** half-float `0x0000` decodes to `3.05176e-05` instead of `0`, so `RGBAf32(0, 0, 0, 0)` does not survive an `f16` round trip; `float.infinity` encodes to `0x3C00` (1.0); NaN encodes to `0x3E00` (1.5); `70000` encodes to `0x7C45`, an IEEE NaN pattern, which the library decodes as `69952`. Data from a file or GPU in this format would be misread at zero, infinity and NaN.
- The rgb9e5 encoder clamps to the representable maximum and `assert`s its exponent and mantissa ranges ([`packedrgb.d` L282-L396][pk-encode]); test values from 0.25 to 100 round-tripped exactly (**verified**).
- Float to integer saturates (`RGBf32(1.5, -0.25, 0.5)` becomes `RGB8(255, 0, 128)`; **verified**), so out-of-gamut results clip silently rather than being reported.
- `@trusted` appears only on the two `PackedRGB` conversions, which pun `uint` and `float` through pointer casts ([`packedrgb.d` L215][pk-float-dec]). The rest is `@safe`. The unittests pass under `-preview=dip1000 -preview=in` and under `-w -de` (**verified**).

### 6. Allocation and ownership

None: every type is a value struct, and all conversions are pure functions of values. The exceptions to `@nogc` are the throwing `colorFromString` and `NormalizedInt.toString`, which calls `std.conv.to!string` ([`normint.d` L37-L41][ni-tostring]). The second has a build consequence: because `NormalizedInt` is a struct with a `toString`, instantiating `RGB8` instantiates `std.conv.to!(string)(double)` and its `Appender`, and an `-betterC` build of a five-line program that only converts colours fails with _"`TypeInfo` cannot be used with `-betterC`"_ (**verified**, LDC 1.43.0). The `@nogc` promise holds; the betterC one, which the header does not make, does not.

### 7. CPU parallelism and SIMD

Absent by design. Every operation is per element and scalar; there is no batch API and no vector type. Evans in review: _"The single-element operators are useless for performance. … I tried a lot, but concluded that the single-element operators and the batch-operators need to be separate functions, and the iteration code (ndslice?) will need to learn how to call the batch operators instead of the single-element operators."_ ([PR comment, February 22, 2017][pr-simd]). Another reviewer proposed shipping the scalar API first and adding batch functions later, and Evans agreed (_"This was my plan."_, [PR comment, February 22, 2017][pr-plan]); 9il replied that a scalar-first API would have to be redone for speed, citing ndslice's own rewrite ([PR comment, February 23, 2017][pr-9il-simd]). Per-element transfer functions call `^^` on `float`/`double`, and there are no lookup tables for 8-bit decode, even though an 8-bit source has only 256 inputs.

### 8. GPU offload and interop

No GPU code. The interop value is in the vocabulary: `PackedRGB` names the GPU packed formats (`rgb_f11_f11_f10` is `B10G11R11_UFLOAT_PACK32`, `rgb_9_9_9_e5` is `E5B9G9R9_UFLOAT_PACK32`, `rgb_5_6_5` is `B5G6R5_UNORM_PACK16`: the library's LSB-first bit offsets match the bit ranges the [Vulkan specification][vk-formats] gives for each), and `NormalizedInt` implements the UNORM and SNORM rules, including SNORM's clamping of the minimum code. Integer narrowing drops low bits instead of rounding: `convertNormInt` from `ushort` to `ubyte` differs from `round(v / 257)`, the result a float-to-UNORM conversion of `v / 65535` would give, for 16,256 of 65,536 inputs (**verified**). Linear-flag types correspond to `_SRGB` versus `_UNORM` formats, but nothing maps between the two vocabularies.

### 9. Temporal, animation and containers

Not applicable: no sequences, frames, timing or containers.

### 10. Testing and conformance

All tests are in-module `unittest` blocks, most of them `static assert`s that also prove CTFE: 43 blocks across the eight modules, none in `lab.d`. The suite passes on DMD 2.112.1 and LDC 1.43.0 (`7 modules passed unittests`; **verified**). The gaps are where the arithmetic is: the RGB↔XYZ tests are empty with `// TODO: needs approx ==` ([`rgb.d` L432-L458][rgb-xyz]), there are no reference vectors (no published sRGB/XYZ/Lab pairs, no CIEDE2000 data), no round-trip property over all 8-bit codes, and no test of a cross-primaries RGB conversion, which is how the matrix-order defect above survived review. One exhaustive check run for this page: 8-bit sRGB to 8-bit linear and back changes 73 of 256 codes, and through 16-bit linear changes none (**verified**), which is the quantitative reason the `linear` flag needs more bits than the encoded form.

---

## Lessons for Sparkles

- **Q5.** Colour semantics in the element type works in D without runtime dispatch: `linear`, `colorSpace` and component order are template values, conversions fold to constants, and the whole surface is `@safe pure nothrow @nogc`. What does not transfer is the closed `RGBColorSpace` enum: CICP enumerates primaries, transfer characteristics and matrix coefficients as code-point tables that grow with each edition, ICC profiles are open-ended, and an image read from disk carries its space at run time. A Sparkles vocabulary needs a descriptor value (primaries, white, transfer, matrix, range) that a static type can name _or_ a runtime field can hold. Today Sparkles has neither: colour is untyped ([existing-code baseline, G4][bl-existing]).
- **Q5.** The descriptor fields are the right first cut (four chromaticities plus transfer pair), and they cover two of CICP's four fields (colour primaries, transfer characteristics), but its matrix coefficients and video-full-range flag have no slot, nor do PQ and HLG, which the [colour papers thread][p-colour] says need BT.2100 formulas generic over float width. A transfer function stored as a pair of `function` pointers is opaque to introspection: nothing can ask whether a curve is the sRGB one and specialise it (an 8-bit lookup table, a GPU format's built-in decode), whereas a named transfer value or an `alias` parameter can be dispatched by `static if`.
- **Q5, Q8.** Chromatic adaptation has to be part of the conversion, not a free helper. The library defines Bradford but never applies it, and its unadapted sRGB-to-Lab output (`b* = -19.4` for white) is the kind of error a reference-vector test catches at once. Adopt its descriptor shape; do not adopt its conversion graph without published test vectors from the [colour papers thread][p-colour].
- **Q1, Q5.** Alpha needs a declared mode and a declared default. The library's default alpha is 0 with a `DEBATE` comment, its XYZ path drops alpha, and it has no premultiplied state; Sparkles already has the split convention ([existing-code baseline, G3][bl-existing]) and opaque-by-default `Rgba` in `sparkles.terminal_view.painter` (`ubyte a = 255;`). A Sparkles element type should carry straight or premultiplied in the type and keep alpha on every conversion path.
- **Q1, Q2.** The component-string template (`"bgra"`, `"rgbx"`, `"la"`) is a compact, introspectable way to name interleaved layouts and is a good fit for design by introspection (`hasComponent!'a'`, `hasAlpha`). It does not extend to planar or sub-sampled data, which needs a pixel-view type above the element ([existing-code baseline, G2][bl-existing]). Generating fields by string mixin hides them from DDoc; `static foreach` over a component list gives the same layout with readable declarations.
- **Q2.** The `ParentColor` plus `static convertColorImpl` protocol is a working example of shell-with-hooks across a type graph, and its own author recorded its limit: hooks cannot be added from outside a type. Sparkles' design-by-introspection guidelines face the same choice; a registry of free conversion templates found through a trait, or a single hub (linear XYZ with a stated white) with every type converting to and from it, avoids the problem.
- **Q3, Q7.** Batch conversion has to be designed in, not added. The author concluded in review that single-element operators are "useless for performance" and that batch operators must be separate functions; the mir maintainer went further and argued that a scalar-first API would need redesigning for speed. The [shaders-SIMD baseline][bl-shaders] notes that `Vector` stores natively only `float`, `int` and `uint`; a colour element type must therefore convert to and from vector lanes in strips, and 8-bit transfer decoding should be a 256-entry table rather than `pow` per sample.
- **Q5, Q6.** `NormalizedInt` is directly useful as a UNORM/SNORM component type: saturating arithmetic, bit-replicating widening and SNORM clamping, all `@nogc`. Two corrections before reuse: narrowing should round to nearest (the rule Vulkan recommends for float-to-UNORM conversion, [Vulkan specification][vk-unorm]) rather than drop bits, and `toString` must be an output-range writer (`toString(W)(ref W)`), which also makes the type betterC-clean.
- **Q4, Q5, Q8.** `PackedRGB`'s compile-time format strings map well to GPU packed formats and to what `sparkles:wired` must describe ([wired baseline][bl-wired]). Its float codec is not conformant at zero, infinity and NaN, and its bit order (LSB first in string order) is the opposite of Vulkan's names ([packed formats][vk-packed]). A Sparkles packed-format layer would need exhaustive round-trip tests for half floats and a naming rule that matches `VkFormat`.
- **Q8.** The test pattern (`static assert` unittests) is cheap and keeps CTFE honest, but the defects found here sat exactly where `approx ==` was missing. Sparkles' `@safe pure nothrow @nogc` unittests with explicit tolerances and published colour vectors would have caught both the matrix-order bug and the missing adaptation.
- **Q9.** The Phobos history is evidence on package boundaries. The proposal stayed open for two and a half years, and its last months of discussion (February 2017) weigh vectorisation against Phobos's release cadence; 9il asked for it to stay a dub package ([comment][pr-9il-plan]) because, in his words, Phobos's "modify-test-release cycle is months vs dub's minutes" ([comment][pr-9il-simd]). A colour vocabulary small enough to sit in a core package (types, descriptors, transfer functions) and a conversion and batch layer that moves faster is one way to read that evidence.

## Strengths

- Colour space, encoding and layout are type-level facts, so mixing linear and encoded values requires an explicit cast and conversions cost no runtime dispatch.
- Uniformly `@safe pure nothrow @nogc`, and conversions fold at compile time.
- The component-string `RGB` template covers every interleaved 8/16/32-bit and float layout with one declaration, with exact sizes and field order.
- `NormalizedInt` is a self-contained, well-tested UNORM/SNORM type with saturating arithmetic.
- `PackedRGB` names sub-byte, half, 11/10-bit and shared-exponent formats with one parser.
- Broad, sourced table of RGB working spaces and illuminants, with the descriptor-to-matrix derivation rather than hard-coded matrices.
- The code still builds and its tests pass on current DMD and LDC, nine years after the last design change.

## Weaknesses

- Direct RGB-to-RGB conversion across primaries multiplies the matrices in the wrong order and returns wrong values; only the path through `XYZ` is correct.
- No chromatic adaptation in any conversion; `Lab` to `Lab` across white points does not compile.
- Alpha defaults to transparent, is dropped through `XYZ`, and has no straight or premultiplied mode.
- The set of RGB spaces is a closed enum; a run-time or user-defined space cannot parameterise `RGB`.
- No HDR (PQ, HLG), no BT.1886, no YCbCr, no CICP, no ICC.
- Half-float and small-float codecs mishandle zero, infinity and NaN.
- Narrowing integer conversion truncates rather than rounds; `NormalizedInt` multiply rounds down.
- No batch or SIMD path; per-sample `pow` for transfer functions.
- Thin numeric testing: empty `approx ==` TODOs, no reference vectors, no tests for `lab.d`.
- `NormalizedInt.toString` pulls `std.conv` into every instantiation and blocks `-betterC`.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                  | Trade-off                                                                                                       |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| Colour space and linearity as template parameters of `RGB`           | Conversions are generated and folded at compile time; mixing spaces needs an explicit cast | A space known only at run time (a file's ICC or CICP) has no type; the space set is a closed enum               |
| Layout as a component string mixed into fields                       | One template covers every interleaved order and padding                                    | Generated members are invisible to DDoc and tooling; planar and sub-sampled layouts are out of reach            |
| Integer components always mean normalised (`NormalizedInt!I`)        | UNORM/SNORM semantics match textures and file formats; saturating arithmetic               | Raw integer channels (counts, labels, HDR integer codes) cannot be expressed; rounding choices are baked in     |
| Each type converts only to its `ParentColor`; paths are derived      | Adding a type needs two functions; any pair converts                                       | Shortcuts bypass the tested hub (the RGB-to-RGB matrix bug); hooks must live inside the type                    |
| `XYZ` without a white point as the hub                               | Simple, absolute-looking centre for all conversions                                        | White-point changes are silently skipped; Bradford is defined but unused                                        |
| Transfer functions as `function` pointers in the descriptor          | One descriptor struct covers hybrid and pure-gamma curves                                  | Indirect call per sample; HDR curves with different shapes (PQ, HLG) would need new pointer pairs and constants |
| Scalar, single-element API only                                      | Minimal, reviewable surface for Phobos; vectorisation deferred                             | The author and reviewers agreed batch operations need separate functions the API does not have                  |
| Propose to Phobos as `std.experimental.color`, published also on dub | A standard vocabulary only helps if every library shares it                                | Two and a half years of review, closed unmerged in August 2017; dependants preferred the faster dub cycle       |

### Review history

| Date              | Event                                                                                                                                                                            |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| January 6, 2015   | [dlang/phobos#2845][pr2845] opened, "Added std.experimental.color"; the first review asks for a code.dlang.org package first ([comment][pr-dub-first])                           |
| June 23, 2015     | "std.experimental.color, request reviews" thread on the D newsgroup; Sönke Ludwig asks for swizzling, a small vector type and RGBA rather than ARGB strings ([archive][ng-2015]) |
| June 24, 2015     | Initial commit of TurkeyMan/color; the registry dates `color` 0.0.1 to the same day ([package][dub-pkg])                                                                         |
| September 2016    | `NormalizedInt`, `colorspace.d`, `Lab`, chromatic adaptation and `PackedRGB` land; a reviewer judges the PR ready for formal review ([comment][pr-ready])                        |
| October 6, 2016   | "color lib" newsgroup thread: "How can I get this to a point where people would like to see it in phobos?" ([archive][ng-2016])                                                  |
| December 31, 2016 | Evans reports "low enthusiasm for inclusion" ([comment][pr-status]); 9il asks to keep it a dub package for DCV ([comment][pr-9il-plan])                                          |
| August 6, 2017    | PR closed unmerged after 160 comments and 273 review comments, pending the formal Phobos review process ([comment][pr-closed])                                                   |
| March 16-18, 2018 | HLG, ACES, F-Log and S-Log3 colour spaces pushed to branches that were never merged                                                                                              |
| April 14, 2020    | `v0.0.9`, the last tag (HSx negative-angle fix)                                                                                                                                  |
| December 15, 2023 | Pinned revision: PR #17 merged, whose one commit (`4346f02`) changes the dub default target from `sourceLibrary` to `library`                                                    |

---

## Sources

- [TurkeyMan/color repository][repo] at `e9d31e416b1718cd2983bf2c39a96814626227c3`: [`package.d`][pkg-head], [`rgb.d`][rgb-template], [`colorspace.d`][cs-desc], [`xyz.d`][xyz-struct], [`lab.d`][lab-struct], [`hsx.d`][hsx-type], [`packedrgb.d`][pk-template], [`normint.d`][ni-struct], [`dub.json`][dub-json].
- [dlang/phobos#2845, "Added std.experimental.color"][pr2845] and its comments, read through the GitHub API.
- [D newsgroup, June 2015: "std.experimental.color, request reviews"][ng-2015]; [D newsgroup, October 2016: "color lib"][ng-2016].
- [`color` on code.dlang.org][dub-pkg] (release dates from the registry API).
- [Vulkan specification][vk-formats] (KhronosGroup/Vulkan-Docs at `a8b088a3f`): format definitions, [packed-format bit order][vk-packed], [float-to-UNORM conversion][vk-unorm]; [ITU-R BT.709][itu-709] and [ITU-R BT.1886][itu-1886].
- Sparkles context: [existing-code baseline][bl-existing], [shaders-SIMD baseline][bl-shaders], [wired baseline][bl-wired], [resampling and colour papers][p-colour], [catalog umbrella][umbrella].
- Experiments: scratch programs outside the repository, built with DMD 2.112.1 and LDC 1.43.0 against `git archive` of the pinned revision; results quoted above as **verified**.

<!-- References -->

[repo]: https://github.com/TurkeyMan/color/tree/e9d31e416b1718cd2983bf2c39a96814626227c3
[dub-json]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/dub.json
[dub-pkg]: https://code.dlang.org/packages/color
[pr2845]: https://github.com/dlang/phobos/pull/2845
[pr-dub-first]: https://github.com/dlang/phobos/pull/2845#issuecomment-68872343
[pr-ready]: https://github.com/dlang/phobos/pull/2845#issuecomment-245855192
[pr-hsx]: https://github.com/dlang/phobos/pull/2845#issuecomment-245791810
[pr-ufcs]: https://github.com/dlang/phobos/pull/2845#issuecomment-245885845
[pr-xyz]: https://github.com/dlang/phobos/pull/2845#issuecomment-246169609
[pr-status]: https://github.com/dlang/phobos/pull/2845#issuecomment-269846486
[pr-9il-plan]: https://github.com/dlang/phobos/pull/2845#issuecomment-269862915
[pr-simd]: https://github.com/dlang/phobos/pull/2845#issuecomment-281567808
[pr-plan]: https://github.com/dlang/phobos/pull/2845#issuecomment-281581356
[pr-9il-simd]: https://github.com/dlang/phobos/pull/2845#issuecomment-281895696
[pr-closed]: https://github.com/dlang/phobos/pull/2845#issuecomment-320486906
[ng-2015]: https://lists.puremagic.com/pipermail/digitalmars-d/2015-June/232881.html
[ng-2016]: https://lists.puremagic.com/pipermail/digitalmars-d/2016-October/259615.html
[pkg-head]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L3-L101
[pkg-intent]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L9-L14
[pkg-nogc]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L23-L26
[pkg-ndslice]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L29-L51
[pkg-custom]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L54-L94
[pkg-iscolor]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L111-L114
[pkg-aliases]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L140-L171
[pkg-convert]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L327-L368
[pkg-parse]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L371-L447
[pkg-parse-impl]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L455-L540
[pkg-worktype]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L542-L564
[pkg-path]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L566-L601
[pkg-path-test]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L602-L621
[pkg-compexpr]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/package.d#L623-L640
[rgb-alpha]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L48-L55
[rgb-template]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L58-L74
[rgb-asserts]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L92-L96
[rgb-comptype]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L98-L107
[rgb-csdesc]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L109-L116
[rgb-fields]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L119-L132
[rgb-rgb2rgb]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L329-L376
[rgb-rgb2rgb-test]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L377-L406
[rgb-xyz]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L408-L458
[rgb-gray]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/rgb.d#L490-L526
[cs-white]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L27-L78
[cs-enum]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L81-L133
[cs-desc]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L150-L175
[cs-matrix]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L185-L218
[cs-cat]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L220-L240
[cs-hybrid]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L242-L296
[cs-tf-aliases]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L298-L310
[cs-gamma]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L312-L332
[cs-table]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L337-L364
[cs-inverse]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/colorspace.d#L416-L431
[xyz-struct]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/xyz.d#L59-L74
[xyz-black]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/xyz.d#L284-L292
[lab-struct]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/lab.d#L38-L48
[lab-lab]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/lab.d#L133-L146
[lab-conv]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/lab.d#L148-L192
[hsx-type]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/hsx.d#L74-L100
[hsx-parent]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/hsx.d#L195-L197
[pk-examples]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/packedrgb.d#L32-L42
[pk-info]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/packedrgb.d#L45-L69
[pk-buffer]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/packedrgb.d#L71-L110
[pk-template]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/packedrgb.d#L112-L125
[pk-float-dec]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/packedrgb.d#L215-L280
[pk-encode]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/packedrgb.d#L282-L396
[pk-float-enc]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/packedrgb.d#L356-L379
[pk-parse]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/color/packedrgb.d#L448-L522
[ni-struct]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/normint.d#L24-L32
[ni-tostring]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/normint.d#L37-L41
[ni-mul]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/normint.d#L93-L106
[ni-example]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/normint.d#L237-L279
[ni-float]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/normint.d#L353-L383
[ni-convbits]: https://github.com/TurkeyMan/color/blob/e9d31e416b1718cd2983bf2c39a96814626227c3/std/experimental/normint.d#L457-L506
[umbrella]: ./index.md
[juliaimages]: ./juliaimages.md
[vk-formats]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/formats.adoc#L56-L58
[vk-packed]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/formats.adoc#L1772-L1775
[vk-unorm]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/fundamentals.adoc#L1754-L1765
[itu-709]: https://www.itu.int/rec/R-REC-BT.709
[itu-1886]: https://www.itu.int/rec/R-REC-BT.1886
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-wired]: ./baseline/wired.md
[p-colour]: ./papers/resampling-colour.md
