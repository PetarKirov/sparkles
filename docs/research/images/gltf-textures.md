# glTF texture handling (specification)

How glTF 2.0 splits a texture into image, sampler and use, which image formats its
extensions admit (`KHR_texture_basisu`, `EXT_texture_webp`, the unmerged `EXT_texture_avif`,
`EXT_texture_astc`), and what an engine importing a glTF asset must therefore do with each
image: the catalog's reference for "the transfer function belongs to the use, not the file".

| Field         | Value                                                                                                                                                                                                                                 |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Specification: AsciiDoc core ([`Specification.adoc`][spec-src]), Markdown extension documents, JSON Schema 2020-12 for the core and draft-04 for extensions                                                                           |
| License       | CC-BY-4.0 for the AsciiDoc specification, `LicenseRef-KhronosSpecCopyright` for Khronos extension documents, `LicenseRef-TBD` for vendor extensions, Apache-2.0 for tooling ([`LICENSE.adoc`][license])                               |
| Repository    | [KhronosGroup/glTF][repo]                                                                                                                                                                                                             |
| Revision read | `1c84b58ba3338be4731ea546fa4138dcbb93d42d` (October 27, 2026, "Update URIs (#2684)"); for `EXT_texture_avif`, the head of [PR #2235][avif-pr], `5cb7518cf9a1bfb8268320026961b21caf5a4aac` (December 25, 2022), which is not on `main` |
| Documentation | [glTF 2.0 specification (registry)][registry] · [extension registry][ext-readme] · [`KHR_texture_basisu`][basisu] · [`KHR_texture_transform`][transform] · [`EXT_texture_webp`][webp] · [KTX 2.0 specification][ktx2-spec]            |
| Category      | GPU and SIMD: GPU texture interchange (scene format)                                                                                                                                                                                  |
| Tier          | B                                                                                                                                                                                                                                     |
| Last reviewed | November 7, 2026                                                                                                                                                                                                                      |

## Overview

### What it solves

glTF is a scene-delivery format, and textures are where it meets the image world. The core
admits two image formats and nothing else; every other format arrives as a texture
extension with an optional PNG or JPEG fallback. The core states the narrowing directly
([`Specification.adoc` L2376][spec-images]):

> "The glTF 2.0 specification supports only image resources stored in PNG and JPEG image
> formats (further defined below). Support for other image formats **MAY** be added by
> extensions or future Specification versions."

For Sparkles the subject is a worked example of a consumer that needs less from an image
library than a viewer does (no ICC, no EXIF, no animation) but more from the GPU side
(per-use sRGB, mipmaps, block-compressed transcoding), and that writes those needs down as
`MUST`s an importer can be tested against.

### Design philosophy

- **Three objects, one join.** _"glTF 2.0 separates texture access into three distinct
  types of objects: Textures, Images, and Samplers."_ ([L2318][spec-tex-overview]). A
  `texture` is `{source, sampler}`; a material slot (`textureInfo`) adds `texCoord` and,
  through extensions, a UV transform.
- **Colour is decided by the reference, not the file.** _"Any colorspace information (such
  as ICC profiles, intents, gamma values, etc.) found in images **MUST** be ignored. The
  effective transfer function (encoding) is defined by a glTF object that refers to the
  image (in most cases it's a texture that is used by a material). The effective color
  gamut for all images that are used as color textures is ITU-R BT.709."_
  ([L2422][spec-colour]).
- **Portability over features.** PNG and JPEG are cut down to the subset every decoder
  handles; the rationale for dropping colour chunks, `eXIf` and APNG is that they _"are not
  universally implemented, can conflict with glTF definitions, and thus they may severely
  impact an asset's portability"_, EXIF orientation above all ([L2455][spec-png]).
- **Fallback by indirection.** A format extension replaces `texture.source` with its own
  `source`, so an old loader still finds a PNG; the registry rules that "a texture image
  format extension must be listed as _required_ unless fallback textures in core formats
  (JPG, PNG) are also supplied" ([`extensions/README.md` L174][ext-required]).

## How it works

### Images: bytes, media type and channel expansion

An `image` names its bytes with exactly one of `uri` (a relative path or a `data:` URL) or
`bufferView` ([L2378][spec-images]); a buffer-view image must declare `mimeType`, and _"The
entire buffer view is used as the image data source, i.e., there is no way to specify start
or end byte offsets"_ ([L2387][spec-images]). When the type is unknown, the loader sniffs:

```text
image/png   8 bytes  0x89 0x50 0x4E 0x47 0x0D 0x0A 0x1A 0x0A
image/jpeg  3 bytes  0xFF 0xD8 0xFF
```

The schema keeps `mimeType` open (`anyOf: const "image/jpeg" | const "image/png" | string`,
[`image.schema.json`][image-schema]), which is how `image/ktx2`, `image/webp` and
`image/avif` enter without a core change. Whatever the format, _"images always have four
color channels: red, green, blue, and alpha"_ ([L2432][spec-colour]): greyscale replicates
into RGB, PNG `tRNS` supplies alpha, and JPEG is always opaque.

The two core codecs are profiled ([L2435–L2509][spec-png]):

- PNG: `cHRM`, `gAMA`, `iCCP`, `sBIT`, `sRGB`, `cICP`, `mDCV`, `cLLI`, `pHYs`, `eXIf` and
  the APNG chunks `SHOULD NOT` be present and `SHOULD` be ignored.
- JPEG: JFIF only, 8-bit, one or three components, only `SOF0`, `SOF1` or `SOF2` (no
  arithmetic, lossless or hierarchical), no `DNL`; an embedded ICC profile `MUST` be
  ignored.

### Textures and samplers

A missing `texture.source` means an extension supplies the image ([L2346][spec-textures]);
a missing `sampler` means repeat wrapping and implementation-chosen filtering
([L2354][spec-textures]). Texture coordinate `(0, 0)` is the upper-left corner
([L2362][spec-textures]), and _"glTF 2.0 supports only static 2D textures"_
([L2324][spec-textures]). Sampler values are OpenGL enums ([`sampler.schema.json`][sampler-schema]):

```json
{ "magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 33071 }
```

that is `LINEAR`, `LINEAR_MIPMAP_LINEAR`, `REPEAT`, `CLAMP_TO_EDGE`. Wrapping is a `MUST`,
filtering a `SHOULD` ([L2519–L2521][spec-samplers]). Mipmaps are generated by the client:
_"client implementations **SHOULD** generate mipmaps at runtime"_, and otherwise collapse
mipmap minification to `NEAREST` or `LINEAR` ([L2547][spec-samplers]). Non-power-of-two
images `SHOULD` be resized on platforms with limited support when the sampler repeats or
mipmaps ([L2604][spec-npot]).

### Material slots fix the transfer function

| Slot                       | Encoding                  | Channels read        | Source                  |
| -------------------------- | ------------------------- | -------------------- | ----------------------- |
| `baseColorTexture`         | sRGB on RGB, linear alpha | RGBA                 | [L2676][spec-basecolor] |
| `emissiveTexture`          | sRGB on RGB               | RGB                  | [L2752][spec-emissive]  |
| `metallicRoughnessTexture` | linear                    | G roughness, B metal | [L2701][spec-mr]        |
| `normalTexture`            | linear                    | RGB to XYZ           | [L2830][spec-normal]    |
| `occlusionTexture`         | linear                    | R                    | [L2848][spec-occlusion] |

The base-colour rule also fixes the order of operations: _"When the texture sampler uses
linear filtering, the transfer function **SHOULD** be decoded prior to linear
interpolation"_, followed by the hint _"Graphics APIs usually support dedicated sRGB texture
format enums"_ ([L2676–L2681][spec-basecolor]). Because the encoding attaches to the slot,
one PNG can legitimately be both a colour and a data texture, and the spec invites channel
packing: occlusion (R) and metallic-roughness (G, B) _"could point to the same texture"_
([L2853][spec-occlusion]).

### `KHR_texture_basisu`: KTX2 plus Basis Universal

The ratified extension adds `textures[i].extensions.KHR_texture_basisu.source` pointing at an
`image/ktx2` image ([`README.md` L28–L38][basisu]), with the expectation that _"engines are
expected to transcode a universal texture format into some block-compressed texture format
supported by the platform"_ ([L34][basisu]). It narrows KTX2 hard ([L140–L207][basisu-rules]):

- ETC1S payloads use `supercompressionScheme` 1 (BasisLZ) and `KHR_DF_MODEL_ETC1S`; UASTC
  payloads use scheme 0 or 2 (Zstandard) and `KHR_DF_MODEL_UASTC`; channel IDs name the
  texture type (RGB, RGBA, Red, Red-Green), and Red and Red-Green `MUST NOT` be sRGB.
- `KTXswizzle` is `rgba` or absent; `KTXorientation` is `rd` or absent (matching glTF's
  upper-left origin); the image is 2D; `pixelWidth` and `pixelHeight` are multiples of 4.
- The DFD must match the use: colour data is `KHR_DF_PRIMARIES_BT709` with
  `KHR_DF_TRANSFER_SRGB`, non-colour data `KHR_DF_PRIMARIES_UNSPECIFIED` with
  `KHR_DF_TRANSFER_LINEAR`.
- A full mip pyramid `SHOULD` be present when the sampler mipmaps or is undefined.
- _"When the high-quality GPU formats (i.e., ASTC or BC7) are not available at runtime,
  engines SHOULD transcode UASTC textures with non-color data to uncompressed RGBA to avoid
  artifacts."_ ([L207][basisu-rules]).

The container mechanics and the transcoder are covered in [KTX-Software][ktx-doc] and
[basis_universal][basis-doc]; this page covers only what glTF adds on top.

### `EXT_texture_webp`, `EXT_texture_avif`, `EXT_texture_astc`, `MSFT_texture_dds`

`EXT_texture_webp` is ratified and has the same shape: a `source` on the texture, `image/webp`
for buffer views, and a best practice that _"WebP images using extended file format (RFC
9649, Section 2.7) should not contain `ICCP`, `ANIM`, or `EXIF` chunks"_
([`README.md` L86][webp]). `EXT_texture_avif` is not in the repository at the pinned revision;
its draft lives only in [PR #2235][avif-pr], whose README targets stills only (_"this
extension is only targeting using AVIF as a replacement for jpeg and png"_,
[L82][avif-readme]) and whose schema link points at `glTF.EXT_texture_avif.schema.json` while
the file committed beside it is named `glTF.EXT_texture_webp.schema.json`
([L77][avif-readme]). `EXT_texture_astc` (Draft) carries raw ASTC in KTX2 for direct upload,
with the same DFD rules, LDR 2D only, and a full mip pyramid as a `MUST`
([`README.md` L141–L164][astc]); it is present in the tree but absent from the registry
list. `MSFT_texture_dds` (Draft, vendor) does the same for DDS ([`README.md` L19–L23][dds]).

### `KHR_texture_transform`

Per material slot, `offset`, `rotation` (radians) and `scale` form `T · R · S` applied to UVs,
plus an optional `texCoord` override ([`README.md` L27–L58][transform]). Values are unbounded
and _"will only produce sane results if the texture sampler's `wrap` mode is `REPEAT`, or if
the result of the final UV transformation is within the range [0, 1]"_ ([L60][transform]).
It is a shader-side concern: no texel is touched.

### Demonstrated: the KTX2 rules and a validator's blind spots

In a scratch directory under `/tmp`, with `ktx-tools` 4.4.2 and ImageMagick from nixpkgs and
the npm package `gltf-validator` `2.0.0-dev.3.10`:

```bash
ktx create --format R8G8B8A8_SRGB --encode basis-lz --generate-mipmap base.png color.ktx2
ktx create --format R8G8B8A8_UNORM --assign-tf linear --encode uastc --zstd 10 \
    --generate-mipmap base.png normal.ktx2
ktx validate --gltf-basisu normal.ktx2   # exit 3
```

- `color.ktx2` (64x64, sRGB, BT.709) passes `ktx validate --gltf-basisu`.
- `normal.ktx2` fails with `error-6304`: the tool kept `KHR_DF_PRIMARIES_BT709` on a linear
  file, which the extension forbids; adding `--assign-primaries none` makes it pass.
- A 66x66 source fails with `error-3103`, _"pixelWidth is 66 which is not an integer multiple
  of 4"_.
- `gltf-validator` reports `UNSUPPORTED_EXTENSION` for `KHR_texture_basisu` and
  `IMAGE_UNRECOGNIZED_FORMAT` for every KTX2 image, so it checks neither the DFD-against-slot
  rule nor the multiple-of-4 rule.
- The same validator accepts one PNG referenced as both `baseColorTexture` and
  `normalTexture` (correct: the slot decides), accepts that PNG although it carries a `cHRM`
  chunk (a `SHOULD NOT`), errors with `TEXTURE_INVALID_IMAGE_MIME_TYPE` and
  `IMAGE_NON_ENABLED_MIME_TYPE` when a WebP image is a core `texture.source`, errors with `INVALID_URI` on a `data:image/jpeg` URL holding PNG
  bytes, and resolves `"uri": "../outside.png"` through the host's resource callback without
  comment.

## Analysis

### 1. Pixel and memory model

The model is deliberately poor: a 2D image always presented as four channels, origin
upper-left, no strides or planes visible. Format extensions add mip levels and block
dimensions (multiples of 4 for Basis, any ASTC block size for `EXT_texture_astc`), but still
2D only. Channel packing (occlusion in R, roughness in G, metalness in B) means a texel's
channels can carry unrelated quantities, so an importer cannot treat RGB as a colour triple
by default.

### 3. Colour and metadata

Two regimes coexist. For PNG, JPEG and WebP, the file's [ICC profile][c-icc], [CICP][c-cicp]
and gamma chunks are ignored and the slot decides the [transfer function][c-tf]; gamut is
always BT.709. For KTX2 (`KHR_texture_basisu`, `EXT_texture_astc`) the DFD must agree with
the slot, so the file is tagged and the tag is checked against the use; an image shared by a
colour slot and a data slot is then invalid. Base-colour alpha `MUST` be linear
([L2676][spec-basecolor]), and in KTX2 `KHR_DF_FLAG_ALPHA_PREMULTIPLIED` is forbidden unless
a material asks for it ([L202][basisu-rules]), so alpha is straight by default
([straight and premultiplied alpha][c-alpha]). [Image metadata][c-meta] (EXIF, XMP) is
dropped, chiefly for EXIF orientation. There is no HDR still path: emissive strength is a
factor, not an HDR texture. Compare the codec-side models in [libwebp][libwebp-3],
[libavif][libavif-3] and [KTX-Software][ktx-3].

### 4. I/O and codec architecture

The import pipeline is a resolution chain before any decoding: walk the texture's format
extensions the loader supports, fall back to `source`, fail if an unsupported extension is
in `extensionsRequired`. Bytes come from a relative path, a base64 `data:` URL or a whole
buffer view inside a GLB `BIN` chunk, and the media type comes from `mimeType`, the URL or
the magic-byte table. The [container][c-container] for compressed textures is KTX2, so a
glTF importer needs a KTX2 reader and a Basis transcoder in addition to stills codecs; the
spec describes no streaming beyond what separate files allow (the URI note says separate
files let applications _"progressively load data"_, [L533–L537][spec-uris]).

### 5. Hostile input and safety

The specification sets no limits: no maximum dimensions, image count or decoded size. Its
safety content is portability-driven profiling (no arithmetic JPEG, no `DNL`, no APNG),
which shrinks the decoder surface as a side effect. Relative paths are only constrained to a
syntax; the spec does not forbid `..` and notes that non-normalized paths _"may be
unsupported or lead to unwanted side-effects -- such as security warnings or cache
misses"_ ([L630][spec-paths]). The validator demonstration shows that path containment is
left to the host's resolver. Every bound a [hostile-input][c-hostile] decoder needs therefore
comes from the image library, not from glTF.

### 8. GPU offload and interop

This is where glTF teaches most. An importer must, per texture use:

- choose an sRGB or UNORM format (or view) from the material slot, so one decoded image may
  need two views (see [Vulkan transfer][vk-3] for the `_SRGB` and `_UNORM` split), which
  Vulkan allows only on an image created with `VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT`
  ([`chapters/resources.adoc` L6589–L6594][vk-mutable]), or two uploads;
- transcode KTX2/Basis to a device-supported block format, and fall back to RGBA for UASTC
  data textures when neither ASTC nor BC7 is supported ([Basis Universal][basis-8],
  [format feature queries][vk-formats]);
- generate mipmaps when the sampler asks and the file does not supply them, and resize
  non-power-of-two images on limited platforms;
- translate OpenGL sampler enums to the backend's sampler, and the UV transform to shader
  uniforms.

[Block-compressed formats and supercompression][c-bc] and [staging and upload][c-staging]
are the shared vocabulary; `KHR_texture_basisu` chooses supercompressed portability,
`EXT_texture_astc` chooses direct upload on hardware that has ASTC.

### 9. Temporal, animation and containers

Static only: PNG animation chunks are excluded, the WebP best practice excludes `ANIM`, the
AVIF draft excludes image sequences, and KTX2 images must be 2D. Video textures are separate
work (`KHR_texture_video`, Initial Draft, [PR #2285][ext-progress]; `MPEG_texture_video` as a
vendor extension).

### 10. Testing and conformance

Conformance is split across tools: `gltf-validator` checks JSON, references, media types
and core images; `ktx validate --gltf-basisu` checks the KTX2 file-level rules; neither, in
the versions run here, checks that a KTX2 file's DFD matches the slot that uses it. The
extensions' rules are written as numbered `MUST`s, which makes them directly usable as test
oracles.

Not covered: 2, 6, 7 (a specification has no genericity mechanism, allocator or CPU kernel of
its own).

## Lessons for Sparkles

- **Q5.** glTF shows a consumer for which the transfer function is a property of the use,
  not of the decoded image. An image type that bakes "is sRGB" into the pixel type would need
  an escape hatch (a reinterpreting view); a tag that is advisory and overridable would not.
- **Q5.** The two regimes (ignore file colour for stills, check the KTX2 DFD against the
  use) mean a colour model needs both "what the file says" and "what the caller asserts", and
  a way to compare them.
- **Q4.** A glTF importer needs PNG and JPEG decoders with a profile switch (reject
  arithmetic, lossless and hierarchical JPEG; skip colour chunks) rather than full decoders;
  the profile is a small, testable configuration surface.
- **Q6.** Per-use sRGB, mip generation, Basis transcoding and block-format selection all sit
  between decode and upload. `ui-vulkan` today uploads images as `R8G8B8A8_UNORM` only
  (glyph atlas pages are `R8_UNORM`)
  ([baseline gaps][bl-existing-gaps], [Vulkan baseline gaps][bl-vk-gaps]); a 3D consumer
  needs that layer outside the UI canvas.
- **Q8.** The `MUST` lists in `KHR_texture_basisu` and the core image sections are ready-made
  oracle tables, and the tools' gaps (no slot-versus-DFD check) mark where a Sparkles test
  would add coverage rather than duplicate it.
- **Q8.** Hostile-input bounds cannot come from glTF; a Sparkles importer would take its
  limits and path containment from the image and I/O layers.
- **Q9.** glTF needs container parsing (KTX2), stills codecs, a transcoder and GPU-format
  logic, but no ICC, EXIF or animation; it is evidence that a GPU-texture consumer can depend
  on a narrower set than a viewer does, which bears on where package boundaries fall.
- **Q1.** Channel packing and the four-channel presentation argue for a pixel model where
  channel semantics are named per use, not implied by RGB order. Whether that is worth the
  complexity is a design question this page does not settle.

## Strengths

- Clean split of image, sampler and use; the slot-defined transfer function removes a whole
  class of "is this texture sRGB" ambiguity.
- Normative profiles of PNG and JPEG shrink the decoder surface and remove EXIF orientation
  surprises.
- Format extensions keep a core fallback, and `extensionsRequired` makes the absence of one
  an explicit load failure.
- `KHR_texture_basisu` pins KTX2 tightly enough that `ktx validate --gltf-basisu` can check it
  mechanically.

## Weaknesses

- No resource limits and no path-containment rule; both are left to implementations.
- The colour rule differs by format: stills ignore embedded colour, KTX2 must declare it and
  match the use, so one image cannot serve two slots once it is KTX2.
- Colour textures are BT.709 with an sRGB or linear transfer function only; JPEG is 8-bit and
  the KTX2 extensions are LDR, so no HDR or wide-gamut texture path exists (PNG bit depth is
  not restricted).
- `EXT_texture_avif` has stayed an open draft since December 2022, with a broken schema link;
  `EXT_texture_astc` is in the tree but missing from the registry list.
- The sampler vocabulary is raw OpenGL enum values.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                                     | Trade-off                                                               |
| -------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Transfer function fixed by the material slot | One image can serve colour and data slots; no file ambiguity  | Embedded ICC, gamma and CICP are discarded; no wide gamut or HDR        |
| Core limited to profiled PNG and JPEG        | Every decoder handles the subset; EXIF orientation is avoided | Other formats need an extension plus a fallback or `extensionsRequired` |
| KTX2 DFD must match the use                  | Mechanically checkable by `ktx validate --gltf-basisu`        | A KTX2 image cannot be shared by a colour and a data slot               |
| Sampler values are OpenGL enums              | Direct mapping for WebGL and OpenGL loaders                   | Every other backend translates them                                     |

## Sources

- [glTF 2.0 specification source][spec-src] at the pinned revision: [textures][spec-textures],
  [images][spec-images], [colour rule][spec-colour], [PNG and JPEG profiles][spec-png],
  [samplers][spec-samplers], [material slots][spec-basecolor], [URIs][spec-uris].
- Schemas: [`image.schema.json`][image-schema], [`sampler.schema.json`][sampler-schema],
  [`texture.schema.json`][texture-schema], [`textureInfo.schema.json`][textureinfo-schema].
- Extensions: [`KHR_texture_basisu`][basisu], [`KHR_texture_transform`][transform],
  [`EXT_texture_webp`][webp], [`EXT_texture_astc`][astc], [`MSFT_texture_dds`][dds],
  [`EXT_texture_avif` draft (PR #2235)][avif-readme], [extension registry][ext-readme].
- [KTX 2.0 specification][ktx2-spec]; Vulkan [`chapters/resources.adoc`][vk-mutable]
  (mutable-format views); catalog pages [KTX-Software][ktx-doc],
  [basis_universal][basis-doc], [Vulkan transfer][vk-doc], [Concepts][concepts].

<!-- References -->

[repo]: https://github.com/KhronosGroup/glTF/tree/1c84b58ba3338be4731ea546fa4138dcbb93d42d
[license]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/LICENSE.adoc#L1-L32
[registry]: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html
[ktx2-spec]: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html
[spec-src]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc
[spec-uris]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L525-L545
[spec-paths]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L626-L631
[spec-tex-overview]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2313-L2318
[spec-textures]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2322-L2366
[spec-images]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2369-L2420
[spec-colour]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2422-L2432
[spec-png]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2435-L2509
[spec-samplers]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2512-L2600
[spec-npot]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2602-L2615
[spec-basecolor]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2676-L2681
[spec-mr]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2701
[spec-emissive]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2752
[spec-normal]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2819-L2839
[spec-occlusion]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/Specification.adoc#L2848-L2853
[image-schema]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/schema/image.schema.json#L13-L40
[sampler-schema]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/schema/sampler.schema.json#L9-L112
[texture-schema]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/schema/texture.schema.json#L8-L17
[textureinfo-schema]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/specification/2.0/schema/textureInfo.schema.json#L8-L21
[basisu]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/extensions/2.0/Khronos/KHR_texture_basisu/README.md#L28-L38
[basisu-rules]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/extensions/2.0/Khronos/KHR_texture_basisu/README.md#L140-L207
[transform]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/extensions/2.0/Khronos/KHR_texture_transform/README.md#L23-L64
[webp]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/extensions/2.0/Vendor/EXT_texture_webp/README.md#L16-L102
[astc]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/extensions/2.0/Vendor/EXT_texture_astc/README.md#L141-L164
[dds]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/extensions/2.0/Vendor/MSFT_texture_dds/README.md#L19-L23
[ext-readme]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/extensions/README.md#L8-L38
[ext-progress]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/extensions/README.md#L42-L57
[ext-required]: https://github.com/KhronosGroup/glTF/blob/1c84b58ba3338be4731ea546fa4138dcbb93d42d/extensions/README.md#L174
[avif-pr]: https://github.com/KhronosGroup/glTF/pull/2235
[avif-readme]: https://github.com/KhronosGroup/glTF/blob/5cb7518cf9a1bfb8268320026961b21caf5a4aac/extensions/2.0/Vendor/EXT_texture_avif/README.md#L75-L101
[ktx-doc]: ./ktx-software.md
[ktx-3]: ./ktx-software.md#_3-colour-and-metadata
[basis-doc]: ./basis-universal.md
[basis-8]: ./basis-universal.md#_8-gpu-offload-and-interop
[vk-doc]: ./vulkan-transfer.md
[vk-3]: ./vulkan-transfer.md#_3-colour-and-metadata
[vk-formats]: ./vulkan-transfer.md#format-feature-queries-for-block-formats
[vk-mutable]: https://github.com/KhronosGroup/Vulkan-Docs/blob/a8b088a3fae12c8575407ea90c7c09bd653db923/chapters/resources.adoc#L6589-L6594
[libwebp-3]: ./libwebp.md#_3-colour-and-metadata
[libavif-3]: ./libavif.md#_3-colour-and-metadata
[concepts]: ./concepts.md
[c-icc]: ./concepts.md#icc-profile
[c-cicp]: ./concepts.md#cicp
[c-tf]: ./concepts.md#transfer-function
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[c-meta]: ./concepts.md#image-metadata
[c-container]: ./concepts.md#container-and-bitstream
[c-hostile]: ./concepts.md#hostile-input
[c-bc]: ./concepts.md#block-compressed-formats-and-supercompression
[c-staging]: ./concepts.md#staging-and-upload
[bl-existing-gaps]: ./baseline/existing-code.md#gaps-and-tensions
[bl-vk-gaps]: ./baseline/vulkan.md#gaps-and-tensions
