# `ae.utils.graphics` (D)

Vladimir Panteleev's image package in the `ae` library: images as compile-time duck-typed _views_ with lazy combinators in the style of `std.range`, colour types generated from channel-name lists, and thin codecs that hand off most formats to libpng, SDL_image, ImageMagick or ffmpeg.

| Field         | Value                                                                                                                                                                        |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | D (templates only; no runtime polymorphism in the core)                                                                                                                      |
| License       | MPL 2.0 (`README.md` "License" section and module headers; relicensed February 14, 2012); the README excepts `hls.d` (licence unclear) and `fonts/font8x8.d` (public domain) |
| Repository    | [CyberShadow/ae][repo], directory [`utils/graphics/`][tree]                                                                                                                  |
| Revision read | `7870bc3cd03cd43fce638fcf3cf5a685cadea70a`                                                                                                                                   |
| Documentation | In-source DDoc; the design article [_Functional image processing in D_][blog] (March 21, 2014)                                                                               |
| Category      | D landscape: generic pixel and view library                                                                                                                                  |
| Tier          | A                                                                                                                                                                            |
| Last reviewed | November 7, 2026                                                                                                                                                             |

> [!NOTE]
> Every quote from the source was read with `git show 7870bc3cd:<path>` at the pinned revision; every cited path was checked with `git cat-file -e`. Claims marked **verified** were demonstrated by compiling the pinned tree (extracted with `git archive`) in a scratch directory under `/tmp` with DMD 2.112.1 and LDC 1.43.0. Everything else is documented, not run. This page builds on [Functional images (Henderson, Pan, Elliott)][fi-doc], which covers the theory, and does not restate it.

## Overview

### What it solves

`ae.utils.graphics` is the image layer of a general-purpose library, used by its author's tools and games. It needs to load, compose, draw on and save small and medium raster images without committing to one in-memory pixel format. The 2014 article states the motivation against the two usual designs:

> From its first iteration, all components of the image processing package were templated by the color type. This is not a conventional way to implement graphics libraries – most libraries abstract away the exact color type the image uses behind an OOP interface, or they simply convert all images to a single in-memory pixel format. ([blog post][blog])

It is the D library that the paper thread [generic image programming][p-generic] names "the closest prior art in D". The thread summarises the 2014 article; this page reads the code as it stands twelve years later.

### Design philosophy

The article names `std.range` and `std.algorithm` as the model:

> The goals for the overhaul were inspired by D's std.algorithm and std.range modules:
>
> - Present everything as small, composable components
> - Avoid implicit copying and prefer lazy evaluation
> - Use templates for efficient code
>
> ([blog post][blog])

The interface is a predicate, as `isInputRange` is:

> This method of defining static interfaces is similar to the one used by D's std.range, e.g. for isInputRange. Instead of defining an interface close to the OOP sense, D static interfaces conventionally are defined by testing if they implement certain features. ([blog post][blog])

The article's performance claim rests on inlining:

> Because the abstraction we use does not rely on runtime polymorphism, the compiler is free to inline calls across all transformation layers. Flipping an image horizontally twice is a no-op – and, indeed, i[5, 5] and i.hflip().hflip()[5, 5] produce identical machine code. ([blog post][blog])

The library does not try to be a codec suite. Its own encoders write uncompressed BMP, unfiltered PNG and binary Netpbm; anything else is piped through an external program.

## How it works

### The view concept

A view is any type with `w`, `h` and a two-argument `opIndex`. Writability and direct (scanline) access are refinements, each a separate `enum` predicate ([`view.d` L27-L51][v-traits], doc comments elided):

```d
alias xy_t = sizediff_t;

enum isView(T) =
    is(typeof(T.init.w) : xy_t) && // width
    is(typeof(T.init.h) : xy_t) && // height
    is(typeof(T.init[0, 0])   );   // color information

alias ViewColor(T) = typeof(T.init[0, 0]);

enum isWritableView(T) =
    isView!T &&
    is(typeof(T.init[0, 0] = ViewColor!T.init));

enum isDirectView(T) =
    isView!T &&
    is(typeof(T.init.scanline(0)[0][0]) : ViewColor!T);
```

`isDirectView` indexes twice (`scanline(0)[0][0]`) because `scanline` returns _storage units_, not colours (see [Pixel and memory model](#_1-pixel-and-memory-model)). The `DirectView` mixin ([L53-L86][v-directview]) derives `opIndex(x, y)`, `opIndexAssign` and a row accessor `opIndex(y)` returning a `Row` struct from `scanline` alone.

### Lazy combinators

Each combinator is a function returning a Voldemort struct that stores its source by value. Three building blocks cover most of them:

- **Generators.** `procedural!formula(w, h)` evaluates `binaryFun!(formula, "x", "y")` on demand ([L97-L118][v-procedural]); `solid` and `onePixel` are procedural views over a captured colour.
- **Coordinate warps.** The `Warp` mixin ([L203-L222][v-warp]) defines `opIndex` as "call `warp(x, y)` on the coordinates, then index `src`", and defines `opIndexAssign` only `static if (isWritableView!V)`. `crop` ([L224-L257][v-crop]), `tile` ([L266-L285][v-tile]), `nearestNeighbor` ([L294-L312][v-nn]), `flipXY` and the string-formula `warp!(xExpr, yExpr)` ([L343-L383][v-warpstr]) are all `Warp` instances. `hflip`, `vflip` and `flip` are one-line aliases of `warp` ([L405-L412][v-flips]), and `rotateCW`/`rotateCCW` compose `flipXY` with a flip ([L426-L436][v-rot90]). `SafeWarp` ([L629-L653][v-safewarp]) returns a default colour for out-of-range source coordinates, which `rotate` uses ([L655-L690][v-rotate]).
- **Colour maps.** `colorMap!fun` ([L708-L733][v-colormap]) is `map` over pixels; the two-function form `colorMap!(getFun, setFun)` ([L735-L765][v-colormap2]) is writable. `invert` is `colorMap!(c => ~c, c => ~c)`.

Composition and layering complete the set: `vjoiner` ([L450-L506][v-vjoiner]) concatenates views vertically with a row-to-child index, `overlay` and `border` ([L521-L571][v-overlay]) place one view over another, `blend` ([L587-L616][v-blend]) alpha-composites a variadic list, and `trim!pred` ([L797-L840][v-trim]) returns the smallest `crop` containing matching pixels.

Capability propagation is design by introspection. `crop` re-exports `scanline` when its source has one and asserts that it did:

```d
        static if (isDirectView!V)
        auto scanline(xy_t y)
        {
            return src.scanline(y0+y)[x0..x1];
        }
    }

    static assert(isDirectView!V == isDirectView!Crop);
```

`warp!(xExpr, yExpr)` goes further: it inspects the user's formula. When `xExpr == "x"` and `yExpr` compiles in a scope with no `x` (the zero-argument template `testWarpY()()`), whole scanlines can be forwarded, so `vflip` of a direct view is itself direct ([L364-L378][v-warpstr]).

A transform is stored in inverse form. `warp` receives the _output_ coordinate and rewrites it to the _source_ coordinate, the pull mapping that Elliott's _Functional Images_ describes as constructing "the transforms in inverted form" (see [the functional-images page][fi-doc]). Unlike Pan's continuous `Point -> Colour`, the domain here is a finite integer rectangle, so a view is close to Pan's sampled `Array2 Int Int ((Int, Int) -> α)` with a bound on each axis.

### Materialisation and bulk operations

`Image!(COLOR, StorageType)` ([`image.d` L72-L117][i-image]) is the owning in-memory view: `xy_t w, h` and a GC slice `StorageType[] pixels`, row-major with no padding. `ImageRef` ([L25-L46][i-imageref]) is the borrowed form, with a `size_t pitch` in bytes and a raw `StorageType*`. `copy(src)` allocates a fresh `Image` and `copy(src, target)` writes into an existing one ([L137-L152][i-copy]); `hjoin`/`vjoin` are the eager counterparts of `vjoiner`.

`blitTo` is the one place bulk access is chosen automatically ([`view.d` L141-L157][v-blit]):

```d
    foreach (y; 0..src.h)
    {
        static if (isDirectView!SRC && isDirectView!DST && is(ViewStorageType!SRC == ViewStorageType!DST))
            dst.scanline(y)[] = src.scanline(y)[];
        else
        {
            foreach (x; 0..src.w)
                dst[x, y] = src[x, y];
        }
    }
```

Algorithms that do not fit the lazy model (`downscale`, `downscaleTo`) take a direct source and a writable target ([`image.d` L233-L384][i-downscale]); the article says "More complicated scaling algorithms are better implemented in an imperative style" ([blog post][blog]).

### Colour types

`Color(FieldTuple...)` ([`color.d` L22-L43][c-color]) is a struct generated from a field specification such as `(ubyte, "r", "g", "b")`. Field names carry the semantics:

> By convention, each field's name indicates its purpose:
>
> - `x`: padding
> - `a`: alpha
> - `l`: lightness (or grey, for monochrome images)
> - others (`r`, `g`, `b`, etc.): color information
>   ([`color.d` L28-L33][c-color])

The common instantiations are aliases ([L305-L328][c-aliases]): `RGB`, `RGB16`, `RGBX`, `RGBX16`, `RGBA`, `RGBA16`, `BGR`, `BGRX`, `BGRA`, `L8`, `L16`, `LA`, `LA16`, `S8`, `S16`, `RGBf`, `RGBd`. Any numeric type is also a valid colour: `Image!int` and `onePixel(42)` appear throughout the tests. Per-channel arithmetic comes from operator overloads, a string-mixin `op!q{...}` ([L219-L246][c-op]), and since 2023 `channelMap` ([L492-L540][c-channelmap]), which matches fields _by name_, so `RGB(1, 2, 3).channelMap!BGR == BGR(3, 2, 1)`.

### Drawing, gamma and codecs

- **`draw.d`** holds imperative operations over any writable view: `fill`, `hline`/`vline`/`line`, `rect`, `fillRect`, `fillCircle`, `fillSector`, `fillPoly`, `thickLine`, soft (anti-aliased) circles and rings, `aaPutPixel`, `aaLine`, `aaFillRect` and `whiteNoise`. Each clipped primitive takes a `bool CHECKED=true` template parameter that compiles the bounds test in or out ([`draw.d` L133-L177][d-check]). A block of pre-2014 code is still present under `version(none):` with the comment "Outdated code from before the overhaul. TODO: fix and update" ([L761-L766][d-none]).
- **`gamma.d`** provides `GammaRamp!(LUM_BASETYPE, PIX_BASETYPE)`, a pair of lookup tables built from a power-law exponent or `ColorSpace.sRGB` ([`gamma.d` L21-L89][g-ramp]), and the lazy views `pix2lum`/`lum2pix` as `colorMap` over the table ([L91-L107][g-views]).
- **In-tree codecs** in `image.d`: binary Netpbm `parsePBM`/`toPBM` (`P5`, `P6`), BMP `viewBMP`/`parseBMP`/`toBMP` with V3 and V4 headers ([L685-L841][i-bmp]; header structs in [`bitmap.d`][bitmap]), and a PNG _encoder_ only, `toPNG`, documented as "Only basic PNG features are supported (no filters, interlacing, palettes etc.)" ([L904-L970][i-png]).
- **Bindings:** `libpng.d` wraps libpng's progressive reader ([`libpng.d` L29-L263][lp-reader]); `sdl2image.d` loads through SDL_image into `Image!RGBX` ([L34-L58][sdl-load]); `gdi.d` is a Windows GDI canvas.
- **Subprocess codecs:** `im_convert.d` pipes bytes through ImageMagick `convert` and reads the BMP it writes back ([L28-L48][im-parse]); `ffmpeg.d` spawns `ffmpeg` with `-vcodec bmp -f image2pipe` and presents frames as a D input range ([L25-L146][ff-in]).

`libpng.d` and `sdl2image.d` are excluded from the root package and built only as the `ae:libpng` and `ae:sdl2` sub-packages ([`dub.sdl` L24-L28][dub-excl], [L156-L181][dub-sub]).

### How the design evolved

`git log` lists 234 commits touching `utils/graphics` up to the pinned revision, back to the 2011 `Canvas` design. The turning points:

| Date       | Commit                   | Change                                                                                                                                |
| ---------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| 2011-09-26 | [`40efe33f`][c-40efe33f] | `Canvas` and a demo: the pre-view design, a mixin-based canvas with `draw`/`transformDraw`                                            |
| 2014-03-18 | [`873480c5`][c-873480c5] | "[BREAKING] Overhaul of ae.utils.graphics": views, `isView`, `Warp`, `Image!COLOR`; coordinates are `int`, `isView` checks `: size_t` |
| 2014-03-21 | [`77ea8352`][c-77ea8352] | `parallel`; the blog post is published the same day                                                                                   |
| 2014-07-15 | [`a1f99f4b`][c-a1f99f4b] | "Allow a cropped view to have a width or height of 0"                                                                                 |
| 2014-12-26 | [`b4dd7045`][c-b4dd7045] | `im_convert`: ImageMagick becomes the general decoder                                                                                 |
| 2015-07-15 | [`d85a14df`][c-d85a14df] | Two-way (writable) `colorMap`                                                                                                         |
| 2019-01-03 | [`01cfcc28`][c-01cfcc28] | `viewBMP`: a BMP file is a zero-copy direct view                                                                                      |
| 2019-01-09 | [`fbfecdc5`][c-fbfecdc5] | libpng binding; strict mode becomes the default the next day ([`8773ff91`][c-8773ff91])                                               |
| 2019-04-28 | [`9b25aea4`][c-9b25aea4] | `safeBlitTo` (clipped blit)                                                                                                           |
| 2020-03-30 | [`0846f0bd`][c-0846f0bd] | "[BREAKING] Introduce support for 1-bit colors": `scanline` returns storage units                                                     |
| 2020-04-02 | [`6cada565`][c-6cada565] | "[BREAKING] Introduce an image coordinate/size type": `int` becomes `xy_t = sizediff_t`                                               |
| 2021-04-09 | [`3979fc04`][c-3979fc04] | "Document Almost Everything": DDoc on every public symbol                                                                             |
| 2023-06-26 | [`9fc71e98`][c-9fc71e98] | `channelMap`, name-matched channel conversion                                                                                         |
| 2024-03-13 | [`da17ff40`][c-da17ff40] | Unit tests guarded by a version, later `debug(ae_unittest)` ([`536b9e70`][c-536b9e70])                                                |

Two of the breaking changes are the ones that matter for Sparkles. The 1-bit change separated _the colour of one pixel_ from _the unit stored in memory_:

> Doing so required separating the type of an individual pixel's color from the type used to store color values on disk / in memory. The most important aspect of this is the DirectView.scanline method now returns "storage unit" types, which act like static arrays of color values ([`0846f0bd`][c-0846f0bd])

The coordinate change records why `int` was dropped, and that the choice is provisional:

> Using a type with a different size than size_t for a very similar concept caused friction due to casts, or code compiling on some target bitness but not another. … It's possible that the type change may be reverted back to `int` (e.g. if a performance regression is observed). The `xy_t` alias will, however, remain, and should be used for semantics. ([`6cada565`][c-6cada565])

## Analysis

### 1. Pixel and memory model

- **One 2-D plane, interleaved channels.** A view is a finite `w × h` rectangle of one colour type. There are no planes (YUV, planar RGB), no channel-strided views, no N-D extents, no mip levels and no tiles. A pixel is always a whole struct.
- **Two strides, in two units.** `Image` has none: `rowSize()` is derived from `w` and the row is contiguous ([`image.d` L112-L116][i-image]). `ImageRef` has `size_t pitch` "In bytes, not COLORs" ([L33][i-imageref]); `viewBMP` uses a signed `sizediff_t pixelStride` so bottom-up BMPs become a negative stride ([L755-L761][i-bmp]). There is no column stride, so a transpose (`flipXY`) is always a per-pixel warp, never a direct view.
- **Storage units.** Since 2020 `scanline(y)` returns `StorageType[]`, where `StorageType` is `PlainStorageUnit!COLOR = COLOR[1]` or a packed `BitStorageUnit` such as `OneBitStorageBE` that exposes eight `bool` pixels through `opIndex` ([`color.d` L567-L604][c-storage]). The `DirectView` mixin indexes `scanline(y)[x / StorageType.length][x % StorageType.length]`. **Verified:** the element type of `Image!RGB.scanline(0)` is `Color!(ubyte, "r", "g", "b")[1]`, not `RGB`.
- **Coordinate type.** `xy_t` is `sizediff_t`, signed and word-sized. The `view.d` comment gives the rationale: "Signed, because operations with image coordinates often involve subtraction, and subtraction with unsigned numbers often leads to trouble" and "Same size as size_t, in order to use the CPU word size and enable seamless interoperability with the .length property of arrays / ranges" ([L19-L27][v-xyt]). **Verified:** `xy_t` is `long` on x86-64, and `p.w - 5` on a width-4 view is `-1`.

**Where it departs from `std.range` and `std.algorithm`.** The reading that the abstraction uses `int` rather than `size_t` was true from 2014 to 2020 and is now partly true: coordinates are signed `ptrdiff_t`, not `size_t`. The precise departures at the pinned revision:

| Convention            | `std.range` / `std.algorithm`                                      | `ae.utils.graphics`                                                                                                                                                                                                                          |
| --------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Index and length type | `size_t` (`length`, `opIndex(size_t)`, `opDollar`)                 | Signed `xy_t` for `w`, `h`, `x`, `y`; but `size_t` for `pitch`, `rowSize()`, `vjoiner`'s `index`, `parallel`'s `chunkSize` and `BitStorageUnit.opIndex`. `foreach (y; 0..v.h)` yields `long`, `foreach (i; 0..pixels.length)` yields `ulong` |
| 2014 form             | —                                                                  | `isView` checked `w`/`h` against `size_t` while every `opIndex` took `int` ([`873480c5`][c-873480c5], [blog][blog])                                                                                                                          |
| Emptiness             | `empty` is a primitive                                             | No `empty`; a view is empty when `w == 0` or `h == 0`, legal since 2014 ([`a1f99f4b`][c-a1f99f4b]). **Verified:** `view.empty` does not compile                                                                                              |
| Length, `$`, slicing  | `length`, `opDollar`, `opSlice(a, b)`                              | None. `crop(x0, y0, x1, y1)` takes half-open corners as four arguments. **Verified:** `img[$ - 1, 0]` and `img[0 .. 2, 0 .. 2]` do not compile                                                                                               |
| Ranges of rows        | A 2-D container is a range of ranges (`chunks`, `ndslice`)         | A view is not a range. **Verified:** `isInputRange!(Image!RGB)` is false and `foreach (row; image)` does not compile. `image[y]` returns `Row` (direct views only), which is not a range. `scanline(y)` is a D slice of storage units        |
| Element type          | `ElementType!R`                                                    | `ViewColor!V`, but bulk access yields `StorageType` (`COLOR[1]`), so `std.algorithm` over a `scanline` sees one-element static arrays                                                                                                        |
| Iteration             | `front`/`popFront`, pipelines terminate in `each`, `copy`, `array` | Index loops. Terminal operations are `copy`, `blitTo`, `toPNG`; eager and lazy pairs follow Phobos naming (`vjoin`/`vjoiner` like `join`/`joiner`)                                                                                           |
| Predicates            | Lambdas; string lambdas are legacy                                 | `binaryFun`/string mixins still in active use: `hflip = warp!(q{w-x-1}, q{y})`, `COLOR.op!q{(a + b) / 2}`                                                                                                                                    |

### 2. Genericity mechanism

Design by introspection throughout: three predicates (`isView`, `isWritableView`, `isDirectView`), optional primitives (`opIndexAssign`, `scanline`) propagated by `static if` through each adapter, and `static assert` to prove the propagation (`crop`). Mixins (`DirectView`, `Warp`, `SafeWarp`) are the shared implementation, which is the "shell with hooks" shape of the repository's DbI guideline. Colour genericity is a second, independent mechanism: `Color!(T, names...)` with name-driven semantics (`a` is alpha, `x` is padding), compile-time field lists (`structFields!COLOR == ["r","g","b"]` selects a PNG colour type in `toPNG`), and `TransformChannelType`/`ChangeChannelType`/`ExpandChannelType` to derive widened or float variants.

There is no runtime dispatch layer: no type-erased image, no "any view" interface. A program that loads an image of unknown format must choose `COLOR` at compile time; the codecs convert to it (libpng through `png_set_*` transforms, ImageMagick through `-type TrueColor`). Constraint failures surface as long template errors; `image.d` cites five compiler bugs as the reason entry points come in two overloads ([L126-L132][i-overloads]).

### 3. Colour and metadata

- **Colour space is not in the type.** `RGB` says nothing about sRGB versus linear; `BGRA` says nothing about straight versus premultiplied alpha. `Color.blend` ([`color.d` L95-L120][c-blend]) computes straight-alpha `over` on integer channels, with the warning on the operators: "overloaded operators preserve types and may cause overflows" ([L180][c-ops]).
- **Gamma is an explicit view.** The 2014 benchmark pipeline linearises with `pix2lum`, filters in 16-bit, and re-encodes with `lum2pix` ([blog][blog]). `ColorSpace` has one member, `sRGB`. The sRGB functions use thresholds `0.0392857` and `0.00303993` with slope `12.9232102` ([`gamma.d` L51-L65][g-ramp]). These are the values at which the linear segment meets the power segment with matching value _and_ slope (`0.055 / 1.4 = 0.0392857`, and `12.9232102` is the slope there), not the IEC 61966-2-1 constants `0.04045`/`12.92`/`0.0031308`; the source links only to Wikipedia's sRGB article and does not say which variant it uses.
- **`hls.d`** converts between RGB and HLS on an integer scale (`HLSMAX=240`, the Windows colour-picker convention, [L10][hls]).
- **No ICC, CICP, HDR, EXIF or XMP.** The BMP V4 header struct declares `bV4CSType`, `CIEXYZTRIPLE` endpoints and gamma fields, and V5 adds `bV5ProfileData`/`bV5ProfileSize` ([`bitmap.d` L59-L80][bitmap]), but `viewBMP` reads none of them; it never reaches even the V4 channel masks (see [I/O and codec architecture](#_4-i-o-and-codec-architecture)). The libpng binding applies `png_set_background` with `PNG_BACKGROUND_GAMMA_FILE` when it flattens alpha and otherwise ignores colour chunks.

### 4. I/O and codec architecture

Three tiers, each with a different contract:

1. **Zero-copy views over bytes.** `viewBMP!COLOR(data)` returns a direct view whose `scanline` points into the caller's buffer ([`image.d` L685-L764][i-bmp]). This is the strongest idea in the codec layer: decoding a raw format is just describing its layout. The colour type must match the file's `bcBitCount` (enforced), so it is a validator, not a converter. The V4 branch is dead: `header` is a `BitmapHeader!3*`, whose `VERSION` is the compile-time constant 3, so `if (header.VERSION >= 4)` never runs and the channel masks are never compared, while colour types that need a V4 header always fail the `static if` check before it ([L728-L748][i-bmp]). **Verified:** `viewBMP!RGBA(Image!RGBA(2, 2).toBMP())` throws "Need a V4+ header to load a Color!(ubyte, "r", "g", "b", "a") image" although `toBMP` wrote a V4 header, and `viewBMP!BGRA` accepts the same RGBA file with red and blue swapped.
2. **A push decoder through libpng.** `PNGReader` is configured at run time (`Depth`, `Channels`, `Alpha`, `AlphaLocation`) and fed with `put(ubyte[])`, which calls `png_process_data`; libpng calls back `infoHandler`, `rowGetter` (where to write row `n`), `rowHandler` and `endHandler` ([`libpng.d` L32-L92][lp-reader]). It is incremental and interlace-aware (`passes`), so a caller can feed network chunks. `decodePNG!COLOR` wraps it for whole buffers ([L265-L358][lp-decode]).
3. **Subprocesses.** `parseViaIMConvert` runs `convert … -[0] … bmp:-` and returns `viewBMP` of the output ([`im_convert.d` L28-L48][im-parse]); `encodeViaIMConvert` does the reverse. This gives every format ImageMagick reads at the price of a process per image.

Encoding writes whole files into fresh `ubyte[]` (`toBMP`, `toPNG`, `toPBM`); there is no output-range writer and no streaming encoder. `toPNG` writes one `IDAT` of unfiltered rows compressed with `std.zlib.compress` ([L904-L970][i-png]). There is no in-tree PNG, JPEG or GIF decoder.

### 5. Hostile input and safety

- **Bounds are asserts and slice checks.** View constructors and `procedural` use `assert`; `Image.scanline` asserts `y` and returns a bounds-checked slice. Codecs use `enforce` (an `Exception`). None of the core is annotated `@safe`, and the codecs cast `data.ptr` to header pointers (`cast(Header*) data.ptr`).
- **`viewBMP` checks.** **Verified** with crafted headers: a negative `bcWidth` (with a small height) and a `bcHeight` of `int.min` (with a small width) are both rejected with "Insufficient data for pixels" by the stride-times-height check; a `bfOffBits` past the end of the buffer escapes as `core.exception.ArraySliceError`, an `Error` rather than the `Exception` the other checks throw, and would be undefined behaviour in a `-boundscheck=off` build. The size check itself overflows: `bitmapPixelStride` computes in `size_t`, and with `bcWidth = bcHeight = int.min` at 32 bits per pixel `pixelStride * abs(h)` wraps to 0 ([L750-L753][i-bmp]). **Verified:** that 118-byte file is accepted as a view with `w = -2147483648`, `h = 2147483648` and a `scanline(0)` of 18446744071562067968 storage units, and `v[1000, 0]` reads 4,000 bytes past the buffer without an error. There are no dimension limits, and the one size check can be bypassed.
- **libpng errors cross C frames as D exceptions.** `libpngErrorHandler` throws: "We must stop execution here, otherwise libpng abort()s" ([`libpng.d` L243-L252][lp-errors]). Unwinding a D exception through libpng's C frames instead of `longjmp` depends on the platform's unwinder and on libpng's frames carrying unwind tables; this was not tested (the `ae:libpng` sub-package needs the `libpng` dub binding, which was not built here). In strict mode, a warning also throws.
- **No size limit in `decodePNG`.** `infoHandler` sizes the `Image` to whatever `IHDR` declares; only libpng's built-in user limits apply. A truncated stream returns the partially filled image without an error (read from the code: nothing checks that `endHandler` ran).
- **SDL path defects (read, not run).** `depalettize` for 1-, 2- and 4-bit images masks the index but never shifts it down, and shifts the mask by the pixel position rather than by `BITS` times it ([`sdl2image.d` L76][sdl-depal]); for a 1-bit image the second pixel's index reads as 2, which throws "Color index exceeds number of colors in palette". The fast path tests `format.Rshift` against 0, 8 and 16 where `Gshift` and `Bshift` were meant ([L91-L94][sdl-fast]), so the condition can never hold and every 32-bit surface takes the per-pixel `SDL_GetRGB` path.
- **No fuzzing**, no corpus, no hostile-input tests anywhere in the tree.

### 6. Allocation and ownership

- **`Image` is a GC slice with value-copy aliasing.** Copying an `Image` struct shares `pixels`; `size()` grows with `pixels.length = size`, which may reallocate and break the sharing. There is no ownership type and no reference count (the Windows `GDICanvas` is the exception: `RefCounted!Data` owns the `HDC`/`HBITMAP`, [`gdi.d` L43-L61][gdi]).
- **Adapters own nothing and copy their source by value**, so a view chain is a nest of small structs on the stack; `vjoiner` and `parallel` allocate (`new Child[]`, `new size_t[h]`, `new Result[]`).
- **Reuse is explicit.** Every allocating entry point has a target overload, and the benchmark keeps `static Image!BGR scratch1` buffers between files ([blog][blog]).
- **Attribute inference, measured.** Nothing in the core is annotated; templates infer. **Verified** with `-preview=dip1000`: a `@safe pure nothrow @nogc` function can build and index `procedural!gradient(64, 64).crop(…).hflip.nearestNeighbor(…).tile(…).colorMap!(…)`, and `blitTo` between two `Image!RGB` infers `@safe @nogc`. The allocating edges do not: `Image.size`, `solid` (its lambda captures `c`, so it needs a GC closure), and the `size(v, w, h)` assertion helper (it formats its message with `std.string.format`) all fail to compile in `@nogc`. The gamma views `lum2pix`/`pix2lum` take `&gamma` of an `auto ref` parameter ([`gamma.d` L93-L98][g-views]); with an rvalue argument the parameter is a by-value copy on the stack, and the returned view keeps a pointer to it. **Verified** with DMD 2.112.1: a function returning `onePixel(RGB16(30000, 30000, 30000)).lum2pix(GammaRamp!(ushort, ubyte)(2.2))` yields 178 per channel when indexed inside the expression and 170 (the `0xAA` a later call wrote to the stack) after it returns. Without `-preview=dip1000` the template infers `@system` ("taking the address of stack-allocated local variable `gamma`"), so a `@safe` caller is rejected; with `-preview=dip1000` the same `@safe` function compiles and returns the dangling view, so dip1000 inference does not catch this escape.

### 7. CPU parallelism and SIMD

`parallel!fun(view, chunkSize)` splits rows into `crop`ped bands, runs `fun` on each through `std.parallelism`, and returns an array of results for `vjoin`/`vjoiner` ([`view.d` L848-L878][v-parallel]). It is fork-join over row bands only; there is no tiling, no halo for neighbourhood filters, and no reduction. There is no explicit SIMD: vectorisation is left to the optimiser over `scanline` slices and `blitTo`'s slice copies.

The article's inlining claim holds. **Verified** with LDC 1.43.0 `-O3 -release -boundscheck=off`: `i[5, 5]` and `i.hflip.hflip[5, 5]` on `Image!L8` compile to the same four instructions plus `ret`; with bounds checks on, the two bodies differ only in the operand order of one `testb`. Of its downscaling benchmark against ImageMagick the article says "The D program runs about 4-5 times quicker" and "it's not a fair comparison"; that number was not reproduced here.

### 8. GPU offload and interop

Not applicable. There is no GPU path; the only foreign surfaces are SDL surfaces (copied into `Image!RGBX`), Windows GDI DIB sections (exposed as a direct view) and `ImageRef` over any pointer and pitch, which is the natural adapter for a mapped staging buffer. The `ae.ui` package has a separate SDL/OpenGL video layer outside `utils/graphics`.

### 9. Temporal, animation and containers

Frames are D ranges. `VideoInputStream` is an input range of `ref Image!BGR` decoded by an `ffmpeg` subprocess, and `VideoOutputStream` is an output range whose `put` writes BMP or PNG frames into `ffmpeg`'s stdin ([`ffmpeg.d` L131-L229][ff-out]). `DecodeStream!COLOR` does the same through ImageMagick, yielding `viewBMP` views of an internal buffer ([`im_convert.d` L91-L210][im-stream]). In both, `front` is invalidated by `popFront` (the buffer is reused), as with `File.byLine`, and the impl is held in `RefCounted` with copying disabled. There are no timestamps, no frame durations, no container parsing and no audio. The article's animated loading icon writes 32 PNGs and leaves GIF assembly to an external tool ([blog][blog]).

### 10. Testing and conformance

- **Unit tests are small and local.** `debug(ae_unittest) unittest` blocks sit beside each function: 13 in `view.d`, 14 in `image.d`, 10 in `color.d` (one `deprecated`), 6 in `draw.d`, 3 in `im_convert.d`, 2 each in `gdi.d` and `hls.d`, and one each in `gamma.d` and `libpng.d`. **Verified:** with DMD 2.112.1, `-unittest -debug=ae_unittest` over `view.d`, `image.d`, `color.d`, `draw.d` and `gamma.d` reports "15 modules passed unittests". CI runs `dub test --debug=ae_unittest` on Ubuntu with DMD and LDC, on Windows with LDC and on macOS with LDC; the `:libpng` sub-package is tested only on Ubuntu with DMD 2.111.0, and no job builds `:sdl2` ([`.github/workflows/test.yml`][ci]).
- **The libpng test is the exception.** It enumerates every combination of output depth, channel order, alpha kind and location against generated PNGs of every bit depth, palette, `tRNS` and `bKGD` setting, skipping the combinations libpng rejects with the reason ([`libpng.d` L360-L459][lp-test]).
- **Many tests only instantiate.** `parseViaIMConvert`, `viewBMP!BGRA` and `encodeViaIMConvert` are tested inside `if (false)`; `toPNG` is called but its output is not decoded. Instantiation-only coverage leaves whole template branches dead, and three are broken at this revision. **Verified:** `parsePBM!L16` fails to compile ("undefined identifier `pixels`", [`image.d` L517-L519][i-pbm]), so 16-bit Netpbm has not compiled since the 2014 overhaul moved the code out of the `Canvas` mixin, where `pixels` was a member; `copyPixels` on 1-bit storage trips its own `assert` because `src.w + (StorageType.length - 1) / StorageType.length` lacks parentheses ([L437-L446][i-copypixels]); and `viewBMP`'s V4 branch never runs (see [I/O and codec architecture](#_4-i-o-and-codec-architecture)), which no test notices because the only V4-capable colour type tested, `viewBMP!BGRA`, sits in `if (false)`. Downscaling with alpha is `static assert(false, "Downscaling with alpha is not implemented")` with a `version (none) // TODO: broken` body ([L257-L291][i-downscale]).
- **No conformance corpus and no oracle.** Neither PngSuite nor any BMP suite is used; there is no comparison against a reference decoder or golden image.

## Lessons for Sparkles

- **Q2: the trait triple transfers almost unchanged.** `isView` / `isWritableView` / `isDirectView`, optional primitives propagated by `static if`, and `static assert(isDirectView!V == isDirectView!Crop)` as an in-place proof are exactly the repository's design-by-introspection guideline applied to pixels, and the [baseline][bl-existing] has no view type at all (its G2). What needs changing is the vocabulary: `w`/`h` names, string-mixin predicates and four-argument `crop` predate the range conventions Sparkles writes to.
- **Q1: index type is a decision with a recorded history.** `ae` moved from `int` to signed word-size `xy_t` for cast friction and explicitly kept the signedness for subtraction. Sparkles' `size_t` convention makes `length`, `opDollar` and `std.algorithm` interoperate but makes `x - r` underflow in neighbourhood code. The evidence here supports separating _extents and indices_ (`size_t`, as ranges want) from _offsets and displacements_ (signed), which `ae` conflates in one alias. See [baseline G2][bl-existing].
- **Q1, Q3: views should also be ranges.** None of `empty`, `length`, `opDollar`, slicing or a range of rows exists, so no `std.range` adaptor composes with a view (verified above). A Sparkles view that exposes rows as a random-access range of row slices, and `opIndex(size_t, size_t)` beside `opSlice` per dimension (the `ndslice` shape), would let `std.algorithm` and `std.parallelism` act on images without bespoke `parallel` and `trim`. Whether mir's `Slice` already is that type is the wave 1 `Slice` experiment.
- **Q1: separate storage units from colours, and add the missing strides.** The 2020 1-bit refactor is the clearest evidence that a pixel view needs a storage-unit concept distinct from its colour type; packed formats, BCn blocks and chroma-subsampled planes are the same problem at larger granularity. `ae` still lacks a column stride, planes and byte-stride uniformity (`Image` has none, `ImageRef` has bytes, `viewBMP` has signed bytes). The [shaders baseline][bl-shaders] gives the GPU-side layout vocabulary (`std140`/`std430`) a view descriptor would meet.
- **Q3: lazy composition costs nothing when it inlines.** The verified identical codegen for `hflip.hflip` supports building on Voldemort adapters, and the measured attribute inference shows the lazy core is `@safe pure nothrow @nogc` for free under dip1000. Inference is not proof of memory safety: the gamma views return a dangling pointer from a function dip1000 accepts as `@safe` (see [Allocation and ownership](#_6-allocation-and-ownership)). What does not transfer is the per-pixel `opIndex` as the only access path for warps: `rotate`, `nearestNeighbor` and `colorMap` lose `scanline` and drop to scalar loops. Halide-style separation of algorithm and schedule (see [papers][p-dsl]) is the counterweight.
- **Q3, Q9: allocation belongs at the edges, as here, but with Sparkles' owners.** `ae`'s split (lazy core, explicit `copy`/`target` overloads at the edges) matches Sparkles rules; replacing `StorageType[] pixels` with `sparkles.base.buffer` (`UniqueBuffer` as default, `HeapBuffer` for large images) and replacing `ubyte[]`-returning encoders with output-range writers closes the gap the [baseline][bl-existing] records as G6. `solid`'s closure is the pattern to avoid: capture by value in a struct, not a delegate.
- **Q4: `viewBMP` is a model for raw formats; the rest of the codec layer is not.** Describing a file's pixel area as a direct view over the input bytes is zero-copy and composes with every combinator, and it is the shape a `sparkles:wired` layout description could generate (see the [`sparkles:wired` baseline][bl-wired]). Its overflowing size check and dead V4 branch are the warning: the layout checks belong in generated code with checked arithmetic, not in hand-written casts. The libpng `PNGReader`'s `rowGetter` callback is a useful precedent for "decoder asks the caller where row `n` goes", which suits caller-owned storage. Subprocess decoding, exceptions thrown through C frames, and encoders without filtering do not fit `@nogc nothrow` or wasm/Android targets.
- **Q5: colour semantics must be in the type or a declared tag.** Channel names give `ae` alpha and padding, but not transfer function, primaries or premultiplication; gamma is a view the caller must remember to insert, and its sRGB constants silently differ from the standard. Sparkles already has a premultiplied/straight split across packages ([baseline G3, G4][bl-existing]); `channelMap`'s name matching is worth keeping for channel order, and is not sufficient for colour.
- **Q8: instantiation is not testing.** Three broken branches (16-bit `parsePBM`, packed `copyPixels`, `viewBMP`'s V4 path) survived years of green CI because their tests never instantiate or run them, and `if (false)` tests only compile. A Sparkles image library should instantiate every capability combination it claims (a `static foreach` over colour and storage types, as `libpng.d`'s test does for formats) and back codecs with corpora and oracles, as the existing `png_oracle` does ([baseline][bl-existing]).
- **Q9: the evidence for a split is in `dub.sdl`.** `ae` keeps the generic core dependency-free and pushes libpng and SDL into sub-packages, so the core builds without system libraries; codec subprocess modules live in the core and pull in `std.process`. That is a working instance of image-core versus image-formats, with the boundary drawn at external dependencies rather than at concept.

## Strengths

- A minimal, compile-time view concept with capability refinements that propagate through adapters automatically and are checked by `static assert`.
- Zero-cost composition, verified: double flips compile away and the lazy core infers `@safe pure nothrow @nogc`.
- Colour types generated from channel names, with name-matched conversion (`channelMap`) and arithmetic that works for any numeric type.
- Zero-copy views over file bytes (`viewBMP`) and foreign memory (`ImageRef`, GDI DIBs).
- A small, readable codebase (about 5,600 lines including bindings, by `wc -l` at the pinned revision) with a design rationale published by the author.
- Packed sub-byte pixels handled by a general storage-unit abstraction rather than special cases.

## Weaknesses

- Views are not ranges: no `empty`, `length`, `$`, slicing or range of rows; mixed signed and unsigned index types.
- No planes, column strides, N-D extents or tiles; a transpose is never a direct view.
- Colour space, transfer function and premultiplication are untyped; one non-standard sRGB curve.
- No in-tree decoders for PNG, JPEG or GIF; the general path is a subprocess.
- Hostile-input handling is incidental: `Error`s on malformed offsets, a size check that overflows into an out-of-bounds view, no size limits, exceptions unwound through C.
- GC ownership with silent aliasing on copy; encoders return arrays instead of writing to a sink.
- Tests that instantiate without exercising, leaving broken branches (16-bit PBM, packed `copyPixels`, `viewBMP`'s V4 path, alpha downscale) and dead pre-2014 code under `version(none)`.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                                | Trade-off                                                                                              |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Views as compile-time duck types (`isView`)                 | Same idiom as `isInputRange`; full inlining across adapters                              | No runtime-typed image; every format choice is a template instantiation and error messages are long    |
| Optional `scanline` propagated by `static if`               | Bulk copies where possible, per-pixel access everywhere else, with no special-casing     | Any warp that touches `x` drops to scalar per-pixel loops; no partial (tile or span) bulk access       |
| Signed word-size `xy_t` (from `int`, 2020)                  | Subtraction safety; no casts against `.length` on 64-bit                                 | Still not `size_t`, so `std.range` interop needs casts; `pitch` and row sizes stay `size_t`            |
| Storage units distinct from colours (2020)                  | 1-bit (and in principle any packed) storage without a separate image type                | `scanline` element is `COLOR[1]`, not `COLOR`; every bulk consumer double-indexes                      |
| Channel semantics by field name (`a`, `x`, `l`)             | Generic blend, padding skip, BMP masks and PNG colour type all derive from the name list | Colour space and alpha convention cannot be expressed; names are strings checked by convention         |
| Transforms stored as inverse coordinate maps                | Pull evaluation: each output pixel asks for its source, so warps compose by nesting      | Forward-only operations (scatter, splat) have no home; resampling quality is limited to nearest sample |
| Formats delegated to libpng, SDL_image, ImageMagick, ffmpeg | Broad coverage with little code                                                          | System dependencies, processes per image, and no control over hostile-input behaviour                  |
| Eager functions take an optional target                     | Callers reuse buffers in loops                                                           | Two overloads per function, which `image.d` attributes to five compiler bugs                           |

## Sources

- [CyberShadow/ae][repo] at `7870bc3cd03cd43fce638fcf3cf5a685cadea70a`: [`view.d`][view], [`image.d`][image], [`color.d`][color], [`draw.d`][draw], [`gamma.d`][gamma], [`bitmap.d`][bitmap], [`libpng.d`][libpng], [`sdl2image.d`][sdl2image], [`im_convert.d`][imconvert], [`ffmpeg.d`][ffmpeg], [`hls.d`][hls], [`gdi.d`][gdi], [`dub.sdl`][dub-excl], [`.github/workflows/test.yml`][ci].
- Commit history of `utils/graphics`, the commits cited in [How the design evolved](#how-the-design-evolved).
- Vladimir Panteleev, [_Functional image processing in D_][blog], March 21, 2014.
- [Functional images (Henderson, Pan, Elliott)][fi-doc], the Sparkles research page on the theory this library samples.
- [Papers: generic image programming][p-generic] and [DSLs and scheduling][p-dsl].
- Sparkles baselines: [existing image code][bl-existing], [shaders, math and host SIMD][bl-shaders], [`sparkles:wired`][bl-wired].

<!-- References -->

[repo]: https://github.com/CyberShadow/ae
[tree]: https://github.com/CyberShadow/ae/tree/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics
[blog]: https://blog.cy.md/2014/03/21/functional-image-processing-in-d/
[fi-doc]: ../ui-backend-seam/functional-images.md
[p-generic]: ./papers/generic-image-programming.md
[p-dsl]: ./papers/dsl-scheduling.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-wired]: ./baseline/wired.md
[view]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d
[v-xyt]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L19-L27
[v-traits]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L27-L51
[v-directview]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L53-L86
[v-procedural]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L97-L118
[v-blit]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L141-L157
[v-warp]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L203-L222
[v-crop]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L224-L257
[v-tile]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L266-L285
[v-nn]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L294-L312
[v-warpstr]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L343-L383
[v-flips]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L405-L412
[v-rot90]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L426-L436
[v-vjoiner]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L450-L506
[v-overlay]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L521-L571
[v-blend]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L587-L616
[v-safewarp]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L629-L653
[v-rotate]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L655-L690
[v-colormap]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L708-L733
[v-colormap2]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L735-L765
[v-trim]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L797-L840
[v-parallel]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/view.d#L848-L878
[image]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d
[i-imageref]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d#L25-L46
[i-image]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d#L72-L117
[i-overloads]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d#L126-L132
[i-copy]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d#L137-L152
[i-downscale]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d#L233-L384
[i-copypixels]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d#L437-L446
[i-pbm]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d#L501-L522
[i-bmp]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d#L685-L841
[i-png]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/image.d#L904-L970
[color]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/color.d
[c-color]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/color.d#L22-L43
[c-blend]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/color.d#L95-L120
[c-ops]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/color.d#L180-L217
[c-op]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/color.d#L219-L246
[c-aliases]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/color.d#L305-L328
[c-channelmap]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/color.d#L492-L540
[c-storage]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/color.d#L567-L604
[draw]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/draw.d
[d-check]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/draw.d#L133-L177
[d-none]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/draw.d#L761-L766
[gamma]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/gamma.d
[g-ramp]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/gamma.d#L21-L89
[g-views]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/gamma.d#L91-L107
[bitmap]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/bitmap.d#L26-L80
[libpng]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/libpng.d
[lp-reader]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/libpng.d#L29-L263
[lp-errors]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/libpng.d#L232-L252
[lp-decode]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/libpng.d#L265-L358
[lp-test]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/libpng.d#L360-L459
[sdl2image]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/sdl2image.d
[sdl-load]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/sdl2image.d#L34-L58
[sdl-depal]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/sdl2image.d#L62-L84
[sdl-fast]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/sdl2image.d#L86-L104
[imconvert]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/im_convert.d
[im-parse]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/im_convert.d#L28-L55
[im-stream]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/im_convert.d#L91-L210
[ffmpeg]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/ffmpeg.d
[ff-in]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/ffmpeg.d#L25-L146
[ff-out]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/ffmpeg.d#L131-L229
[hls]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/hls.d#L10
[gdi]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/utils/graphics/gdi.d#L34-L77
[dub-excl]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/dub.sdl#L24-L28
[dub-sub]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/dub.sdl#L156-L181
[ci]: https://github.com/CyberShadow/ae/blob/7870bc3cd03cd43fce638fcf3cf5a685cadea70a/.github/workflows/test.yml
[c-40efe33f]: https://github.com/CyberShadow/ae/commit/40efe33fd853a0296882d59f9f6a2e1ffc2e822a
[c-873480c5]: https://github.com/CyberShadow/ae/commit/873480c5b1f59cc19c1892aafaa3f471db02b990
[c-77ea8352]: https://github.com/CyberShadow/ae/commit/77ea8352cb0acb7a7e9d0ad532a76984fa1fddb5
[c-a1f99f4b]: https://github.com/CyberShadow/ae/commit/a1f99f4b03dbf7cd16f733517defdd4eff7728f4
[c-b4dd7045]: https://github.com/CyberShadow/ae/commit/b4dd7045aa42465c102d1cda56cfcedf97d56a42
[c-d85a14df]: https://github.com/CyberShadow/ae/commit/d85a14dfb3fb2520d26f06de5e7374ab7ec03314
[c-fbfecdc5]: https://github.com/CyberShadow/ae/commit/fbfecdc589bc3f46738bd1b1a736b77493a4b655
[c-8773ff91]: https://github.com/CyberShadow/ae/commit/8773ff912ee649a37135e8dd7e08c4a0f6e88cbb
[c-01cfcc28]: https://github.com/CyberShadow/ae/commit/01cfcc28a0452d34c60251571ce17914a716376e
[c-9b25aea4]: https://github.com/CyberShadow/ae/commit/9b25aea494659dbadf0be1b59369ce8c30c836b6
[c-0846f0bd]: https://github.com/CyberShadow/ae/commit/0846f0bd17265ae1504978549591d641e9526484
[c-6cada565]: https://github.com/CyberShadow/ae/commit/6cada565174b3b6fa47bcc24d4b0b67b1069186a
[c-3979fc04]: https://github.com/CyberShadow/ae/commit/3979fc046a556b55825792d959f3e3a95ff4fd15
[c-9fc71e98]: https://github.com/CyberShadow/ae/commit/9fc71e98547e3a3751e05a31bdd26789b84cf9ec
[c-da17ff40]: https://github.com/CyberShadow/ae/commit/da17ff40d42bd0262f8381de18428cec89653638
[c-536b9e70]: https://github.com/CyberShadow/ae/commit/536b9e70afa020e012f583a6e30f6a394c996bfe
