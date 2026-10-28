# Sparkles baseline: existing image code, consumers and test oracles

An evidence-grounded inventory of every place pixels already exist in the `sparkles` monorepo (codecs, display-list image types, terminal protocols, GPU uploads, golden-screenshot diffing, oracle precedents), so the `sparkles:{image,video}` design can see what it extends, what it must replace and what it contradicts.

| Field          | Value                                                                                                                                                                                                                                                                                                                            |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Packages       | `sparkles:font`, `sparkles:ui`, `sparkles:ui-tui`, `sparkles:tui`, `sparkles:ui-app`, `sparkles:ui-raylib`, `sparkles:ui-vulkan`, `sparkles:terminal-view`, `sparkles:doc-view`, `sparkles:base`, `sparkles:font-oracle`, `apps/hue`; draft `sparkles:image` (branch `refactor/image-png`)                                       |
| Specs read     | `docs/specs/ui/effects.md` (`IMG1`-`IMG5`), `docs/specs/design-system/` (`GLY9`, `CAP3`, `D34`), `docs/specs/font/` (`FTR7`, `FTX4`), `docs/specs/ui-vulkan/` (`UVK24`, `UVK29`, `UVK30`, `UVX11`), `docs/specs/hue/media.md`, `docs/specs/hue/gui.md` (`DBG1`), `docs/specs/font-explorer/` (`SPEC.md`, `PLAN.md`, `design.md`) |
| Status summary | Two PNG decoders and one encoder SHIPPED on this branch; image registry, cell ladder, kitty and sixel SHIPPED; unified `sparkles:image` PNG codec DRAFT (unmerged branch); JPEG, WebP, GIF, KTX2, video, N-D tensors, colour management, an image oracle package PLANNED or absent                                               |
| Last reviewed  | October 27, 2026                                                                                                                                                                                                                                                                                                                 |

> [!NOTE]
> Everything below is read from files on branch `feat/images` (`483c3676c`) unless it says "DRAFT" (read with `git show refactor/image-png:<path>`, tip `672888e9f`, not checked out in this worktree). The user is merging the two PNG decoders separately; this document records them as known duplication and does not argue for or against the merge.

## What exists today

The four statuses are kept apart. A row appears under one heading only.

### SHIPPED: code on this branch

**Two PNG decoders and one encoder.**

| Property              | `sparkles.font.png` (`libs/font/src/sparkles/font/png.d`, 412 lines)                                                                                                                        | `sparkles.ui.png` (`libs/ui/src/sparkles/ui/png.d`, 574 lines)                                                                                                  |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Purpose               | Bitmap colour strikes of fonts (`CBDT`, `sbix`)                                                                                                                                             | Kitty graphics, screenshot capture, image files                                                                                                                 |
| Colour types / depths | 8-bit greyscale, grey+alpha, RGB, RGBA; indexed 1/2/4/8; `tRNS`                                                                                                                             | Every colour type, 1- to 16-bit samples, `tRNS`                                                                                                                 |
| Interlace (Adam7)     | Refused: `unsupportedVersion`                                                                                                                                                               | Decoded (`passes`, `Pass`)                                                                                                                                      |
| 16-bit                | Refused: `unsupportedVersion`                                                                                                                                                               | Decoded; keeps the high byte (`byteOf`)                                                                                                                         |
| Chunk CRC             | Not checked (module header); zlib Adler-32 is                                                                                                                                               | Not checked ("as stb_image does"); DEFLATE's own checks run                                                                                                     |
| Output                | Premultiplied RGBA, `premultiply` is `(channel * alpha + 127) / 255`                                                                                                                        | Straight 8-bit RGBA                                                                                                                                             |
| Size limit            | Width and height at most `int.max`; inflated size at most `uint.max`; arithmetic overflow is `arithmeticExhausted`; otherwise bounded by the caller's storage                               | `maxPngPixels = 1UL << 26` (comment: 256 MiB of RGBA); inflated stream must be exactly the declared length (`inflateExactly`)                                   |
| Scratch strategy      | Caller storage only: `decodePng(png, rgba, inflated, zlibScratch, ...)`; `pngZlibScratch = 48 * 1024`; a bump allocator (`Bump`, `bumpAlloc`) is handed to zlib; the call is cast to `pure` | Allocating: `new ubyte[]` for raw scanlines and row buffers, `idat ~= chunk`, `chunk.dup` for `PLTE`/`tRNS`; calls `etc.c.zlib` `inflate` directly (`@trusted`) |
| Attributes / errors   | `@safe pure nothrow @nogc` (module-level); `FontResult!PngImage` with kind and offset (`FontErrorKind`)                                                                                     | `@safe nothrow` (not `pure`, not `@nogc`); `bool` or `null`, no reason                                                                                          |
| Encoder               | none                                                                                                                                                                                        | `encodePng`: 8-bit RGBA, one `IDAT` of unfiltered rows, `std.zlib.compress`, writes CRC-32 (`std.digest.crc`)                                                   |
| Oracle                | `sparkles-font-oracle` `oracle.colour.strikes` (HarfBuzz extents and PNG bytes)                                                                                                             | `sparkles.ui_raylib.png_oracle` (stb_image over PngSuite)                                                                                                       |

**Colour glyphs in `sparkles:font`.** `libs/font/src/sparkles/font/colour_raster.d` defines `Colour` (straight sRGB, as `CPAL` stores it), `ColourRegion` (caller-owned premultiplied RGBA, `stride` bytes per row), `ColourGlyph`, `ColourSource` and the dispatch `colourMeasure` / `rasterizeColourGlyph`; `colr.d` renders `COLR` version 0 layers (at most 1,024, `FontLimit`) source-over into the region; `bitmap.d` (`bitmapGlyph`, `rasterizeBitmapGlyph`, `bitmapMeasure`) reads `CBLC` index formats 1 to 5, `CBDT` image formats 17/18/19 and `sbix` `png ` records, and resamples by area-weighted mean ("Nothing allocates"). `COLR` version 1 paint graphs are not rendered (module header).

**The toolkit image model (`libs/ui/src/sparkles/ui/image.d`, 389 lines).** `ImageHandle = Handle!ImageTag` (generational handle from `sparkles.base.pool.handle`); `ImageData` holds `const(ubyte)[] rgba` ("borrowed, not owned"), `Size size`, `string alt`, `uint generation`; `ImageRegistry` has `register`, `replace`, `remove`, reusing a slot under a new generation (commit `103151c4a`); `ImageFit` is `fill`, `contain`, `cover`. The header states "The toolkit does not decode, and does not draw." Pixels are 8-bit RGBA only; `image.d` never says whether alpha is straight or premultiplied, but `libs/ui-vulkan/src/sparkles/ui_vulkan/shading_test.d` states "An image's texels are straight", while `colour_raster.d` regions are premultiplied: two conventions meet at the glyph/image boundary.

**Image on the cell grid (`GLY9` ladder).** `libs/ui/src/sparkles/ui/image_raster.d` (473 lines): `ImageRung` (`alt`, `braille`, `halfBlocks`, `quadrants`, `sextants`, `octants`, `native`), `imageRungOf(TargetCapabilities)`, `rasterCell`, `paintImageRaster`, area sampling (`sampleArea`) into two-colour cells; `blockOctantGlyphs` comes from `sparkles.base.text.unicode_tables`.

**Terminal image protocols.**

- Kitty: `libs/tui/src/sparkles/tui/images.d` (359 lines), `ImagePlacement`, `KittyImages`; raw 32-bit RGBA (`a=t,f=32`), base64 in 3072-byte chunks via `encodeBase64`, `q=2` so no replies; transmitted once per image and generation; placements diffed like cells.
- Sixel: `libs/tui/src/sparkles/tui/sixel.d` (356 lines), `writeSixel`, `SixelImages`; fixed 6x7x6 palette (252 entries).
- iTerm2: `ImageProtocol.iterm2` exists as an enum member ("OSC 1337") in `libs/base/src/sparkles/base/term_caps.d`; a repository-wide grep for `1337` in `*.d` finds no emitter. Detected-or-named only, not drawn.
- Probing: `Terminal.probe` (kitty graphics query, `CSI 16 t`, DA1 sentinel), `TermCaps`, `ImageProtocol` (`none`, `sixel`, `iterm2`, `kitty`, `pixels`).
- Wiring: `libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d` (`kittyPlacement`, `ImageRung` choice), `libs/ui-tui/src/sparkles/ui_tui/session.d` (`ImagePlacement[] placements` field), `libs/ui-app/src/sparkles/ui_app/tui_loop.d` (`images(const(ImageRegistry)*)`).
- The branches `feat/tui-image-protocol` and `feat/design-system-image-ladder` are not ancestors of `HEAD`, but `git cherry HEAD <branch>` prints every commit with a leading minus, meaning an equivalent patch is already in `HEAD`. Their content (files above) is on this branch.

**Receiving images from programs in an embedded terminal.** `libs/terminal-view/src/sparkles/terminal_view/png_decoder.d` installs `sparkles.ui.png.decodePngInto` as libghostty's PNG callback (`GHOSTTY_SYS_OPT_DECODE_PNG`), decoding into a buffer from libghostty's allocator. `kitty_images.d` (`KittyImageRenderer`: `maxImages = 256`, `maxBytes = 320UL * 1024 * 1024`, `UniqueBuffer`) caches textures; `painter.d` defines `PixelLayout` (`gray`, `grayAlpha`, `rgb`, `rgba`), `ImagePixels`, `TextureId`, `isTextureSink`; `vulkan_images.d` (`VulkanImages`) keeps pane images in a shared `ImageRegistry` (`UVX11`); `raylib_painter.d` and `vulkan_painter.d` upload them. Raw (non-PNG) kitty formats are handled inside libghostty, not by sparkles (not verified in the libghostty source).

**GPU uploads.**

- Raylib: `libs/ui-raylib/src/sparkles/ui_raylib/image_textures.d` (`ImageTextures`: cache keyed by handle, revalidated by generation).
- Vulkan: `libs/ui-vulkan/src/sparkles/ui_vulkan/canvas.d` (`CachedImage`, `GpuImage`, `VK_FORMAT_R8G8B8A8_UNORM`, upload budget `ulong uploadBudget = 16 << 20` per frame), `upload.d` (`Uploads`, staged buffer-to-image copies, barriers), `glyph_atlas.d` (interim single-channel glyph pages, `takeDirty`), `resources.d`.
- Image file viewing: `libs/doc-view/src/sparkles/doc_view/kind.d` (`imageExtensions = ["png", "gif", "qoi"]`, comment "raylib's default formats"); `pane.d` (`ImageTexture` loads with raylib `LoadTexture`, GUI only).
- No texture-compression formats: a grep for `ktx2`, `basis`, `dlpack`, `ndslice` across `libs`, `apps` and `nix` finds no image code using them (the matches are guideline prose and `libs/base/src/sparkles/base/buffer.d`, not read for relevance).

**Screenshots and goldens.**

- GUI: `HUE_GUI_SCREENSHOT` (`apps/hue/src/gui_state.d`, `window.screenshot` in `libs/ui-raylib/src/sparkles/ui_raylib/window.d` via `LoadImageFromScreen` + `ExportImage`); native Vulkan loop writes `encodePng` output (`libs/ui-app/src/sparkles/ui_app/native_loop.d`, function around line 1052).
- `apps/hue/tools/gui-ab.d`: compares two builds' PNG captures by byte equality (`oldPng == newPng`) after requiring each side to be self-reproducible; display number pinned; uses raylib's CPU-side image API.
- `apps/hue/tools/tui-ab.d`: pty byte-stream A/B; `capture-goldens.d` text goldens; `capture-modes.d` PNGs "for a human to eyeball".
- `sparkles.base.buffer.checkToString` / `checkWriter` are the text-rendering assertion helpers (used in 46 files by grep), not image helpers.

**Hue.** `apps/hue/src/explorer.d` has an icon for `png`, `jpg`, `jpeg`, `gif`, `svg`, `webp`, `bmp`, `ico` (an icon only). Image display exists as the doc-view image pane above. The markdown image inline remains a placeholder glyph per `docs/specs/hue/media.md` (not verified in code).

**Pixel-adjacent shared infrastructure.** `sparkles.base.buffer` (`UniqueBuffer`, `SharedBuffer`, `HeapBuffer`, `InlineBuffer`, `Buffer`), `sparkles.base.pool` (`Handle`, `SlotTable`, `Pool`, `TextPool`), `sparkles.base.text.cstring`, `sparkles.base.text.simd_caps` (internal immutable AVX-512 flags detected at startup under LDC x86_64, feeding `utf8_simd`), `sparkles.base.hw_caps` (`hwParallelism`), `libs/math` (`vector.d`, `matrix.d`), `libs/event-horizon` (`io.d`: `read(h, buf, offset)`, `vfs.d`), `libs/ui/shaders/effects.d` (shader sources in D).

### SPECIFIED: spec text that is accepted

Spec IDs with verbatim text are in the next section. Summary: `IMG1`-`IMG5` (`docs/specs/ui/effects.md`), `GLY9` and `CAP3` and `D34` (`docs/specs/design-system/`), `FTR7` and `FTX4` (`docs/specs/font/`), `UVK24`, `UVK29`, `UVK30`, `UVX11` (`docs/specs/ui-vulkan/`), `DBG1` (`docs/specs/hue/gui.md`). `D34` is marked `proposed` in `decisions.md` line 73 while its consequences are implemented; do not call it accepted.

The font-explorer spec (`docs/specs/font-explorer/SPEC.md`, `status: accepted`, reviewed 2026-10-06) is the template for a metadata explorer: `inspect` subcommand (text or JSON) plus a window-and-terminal explorer that shows specimens as images, with a labelled placeholder where a terminal lacks the kitty protocol. Its `PLAN.md` marks every area (`A1`-`A6`) `not started`, so it is a design template, not shipped code.

### DRAFT or UNMERGED

- `sparkles:image` (branch `refactor/image-png`, three commits `5c711097f`, `15048a682`, `672888e9f`, dated 2026-10-27, checked out in a sibling worktree): `libs/image/src/sparkles/image/png.d` (655 lines), `png_test.d`, `docs/libs/image/index.md`. Per its header: `pngHeader` / `decodePng` into caller-owned storage as straight or premultiplied RGBA (`Alpha.straight`, `Alpha.premultiplied`), every colour type and depth, `tRNS`, Adam7, allocation-free; `decodePngAlloc` convenience; `encodePng` moved; typed `PngError` with `PngErrorKind` (`truncated`, `malformed`, `unsupported`, `tooLarge`, `callerStorage`) and file offset, as `Expected` (`PngResult`). `maxPngPixels = 1UL << 26` and `pngZlibScratch = 48 * 1024` carry over. The other two commits delete `sparkles.ui.png` and turn `sparkles.font.png` into a wrapper, changing `FTR7` and `FTX4`. None of this is on `feat/images`.
- Everything else in the "Flat" (`WFL`) binary-layout line of work: `docs/research/binary-formats/comparison.md` calls it "the draft at the pinned revision"; the draft spec itself is not in this tree (not verified).

### PLANNED or absent

- `docs/research/images/baseline/` and `docs/research/images/papers/` exist; `papers/` is empty. No `sparkles:video` text exists anywhere read.
- hue media (`docs/specs/hue/media.md`): `IMG1`-`IMG4` (local raster in markdown, SVG, remote opt-in, decode-failure fallback) and `MDB1`-`MDB6` are `not started`; `IMG5` image diff is "researched/not started".
- Formats: JPEG, WebP, GIF decode (named in `kind.d` only because raylib decodes them), QOI (raylib), AVIF/JXL/HEIC, TIFF/EXR/HDR, KTX2/Basis, video containers and codecs: no sparkles code.
- Colour management (ICC, transfer functions beyond sRGB, HDR), EXIF/XMP metadata, N-D arrays, DLPack: no code.
- A differential fuzzing practice: no `libFuzzer`/AFL harness for codecs found; `docs/specs/toolchain/testing.md` lists "Sanitizer, profile and fuzzer runtimes" as toolchain items; its runtimes table gives them status `planned` with per-host entries "to record" (not read in full).

## Contracts that constrain image and video work

Quotes are verbatim; line numbers are of the file on this branch.

| ID      | File and line                                 | Quote                                                                                                                                                                                                                                                                                                                                              | Constrains                                       |
| ------- | --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `IMG1`  | `docs/specs/ui/effects.md:86`                 | "The op vocabulary must carry an **image** op addressing a decoded image by opaque handle, with a destination `Rect` in cells and a declared fit (fill, contain, cover). The op must not grow `DrawOp` past its current 64-byte budget."                                                                                                           | Any new image op: handle-addressed, 64 bytes     |
| `IMG2`  | `docs/specs/ui/effects.md:87`                 | "An `Image` widget must participate in layout as an ordinary box: an intrinsic cell size derived from pixel size and the canvas's cell metrics, subject to the same constraints as any other widget."                                                                                                                                              | Layout needs pixel size only, never pixels       |
| `IMG3`  | `docs/specs/ui/effects.md:88`                 | "Image data must be owned by a **registry outside the widget tree**, keyed by a generational handle, so the flat arena stays flat and a relayout never re-decodes. A removed image's slot may be reused, but only under a new generation: a stale handle resolves to nothing, and the registry holds no more slots than it ever held live images." | Ownership and identity of decoded images         |
| `IMG4`  | `docs/specs/ui/effects.md:89`                 | "A canvas that cannot draw raster content must degrade **visibly and declaredly** — a placeholder box carrying the image's alt text — never silently skip the op."                                                                                                                                                                                 | Every codec failure must still show alt text     |
| `IMG5`  | `docs/specs/ui/effects.md:90`                 | "`ui-tui` must draw images through a terminal image protocol where one is detected, and fall back to `IMG4` otherwise. Protocol detection is the terminal's, not the toolkit's."                                                                                                                                                                   | Terminal graphics path                           |
| `GLY9`  | `docs/specs/design-system/glyphs.md:267`      | "An image **must** render by the ladder **protocol → block raster (`blocks` level) → braille → alt text**. The placeholder's cell size **must** be the same on every rung, so layout never depends on which rung a target reached (`WGT22`)."                                                                                                      | Cell-raster fallback; layout independence        |
| `CAP3`  | `docs/specs/design-system/capabilities.md:89` | "Every terminal-detectable row **must** be **answerable by the toolchain**, onto the same `TermCaps` value: environment-derived answers by `sparkles:base`, query-derived answers by `sparkles:tui`. A query **must** have a bounded timeout and a DA1 sentinel, so a non-responding terminal never blocks."                                       | Image-protocol detection (status: partial)       |
| `D34`   | `docs/specs/design-system/decisions.md:150`   | "A window's own pixels reach whatever a protocol does, so `meet(pixels, kitty)` is `kitty`." (status `proposed` at line 73)                                                                                                                                                                                                                        | `ImageProtocol.pixels` is top of the image order |
| `FTR7`  | `docs/specs/font/SPEC.md:506`                 | "`CBDT`/`CBLC` and `sbix` glyphs **must** decode from their embedded PNG data in 8-bit greyscale, greyscale with alpha, RGB or RGBA, or indexed colour at 1, 2, 4 or 8 bits, without interlacing. Other PNG forms yield `unsupportedVersion`."                                                                                                     | Today's font PNG forms (changed by the draft)    |
| `UVK24` | `docs/specs/ui-vulkan/SPEC.md:276`            | "An image **must** be placed by `fitRect`, clipped to its rectangle for `cover`, sampled through a linear-filtering sampler, and its texels multiplied by the operation's foreground alpha."                                                                                                                                                       | GPU image sampling: linear only                  |
| `UVK29` | `docs/specs/ui-vulkan/SPEC.md:304`            | "A frame's uploads **must** fit a budget fixed at canvas creation; `UVK25` defers what does not fit."                                                                                                                                                                                                                                              | Per-frame upload budget                          |
| `UVK30` | `docs/specs/ui-vulkan/SPEC.md:307`            | "Uploads **must** be recorded before the frame's rendering pass, followed by a barrier from the transfer write to the fragment shader's read. An atlas page **must** be append-only while any frame in flight samples it: written regions are never rewritten until every slot that referenced the page has signalled."                            | Upload ordering                                  |
| `DBG1`  | `docs/specs/hue/gui.md:137`                   | "`HUE_GUI_SCREENSHOT=<path>` must render a few warm-up frames then write a PNG and exit (headless golden capture). The capture must also be **reproducible**"                                                                                                                                                                                      | Goldens are byte-compared PNGs                   |

Standing rules from `AGENTS.md` (read this session): `@safe pure nothrow @nogc` code reports errors with `expected` (`ok(v)` / `err!T(e)`); new code takes writers rather than returning strings; non-templates annotate attributes, templates infer; `-preview=in -preview=dip1000` in every sub-package; test files are never `package.d`; `@betterC`, `@wasm` and `@slow` are test-runner markers; environment-dependent tests call `skipTest`; pinned corpora arrive as `$SPARKLES_FLAKE_INPUT_<NAME>`, which a test must assert is set.

## Capability table

| Capability                             | Where                                                                           | Status                      | Evidence                                                                                                                      |
| -------------------------------------- | ------------------------------------------------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| PNG decode, `@nogc`, caller storage    | `libs/font/src/sparkles/font/png.d`                                             | SHIPPED (limited forms)     | `decodePng`, `pngZlibScratch`, module header "allocating only from the caller's `zlibScratch`"                                |
| PNG decode, all forms, allocating      | `libs/ui/src/sparkles/ui/png.d`                                                 | SHIPPED                     | `decodePngInto`, `decodePng`, `passes`, `maxPngPixels`                                                                        |
| PNG decode, all forms, `@nogc`, typed  | `libs/image/src/sparkles/image/png.d` on `refactor/image-png`                   | DRAFT                       | `git show 5c711097f`; `PngError`, `Alpha`                                                                                     |
| PNG encode (unfiltered, 8-bit RGBA)    | `sparkles.ui.png.encodePng`                                                     | SHIPPED                     | Used by `native_loop.d`; no filtering, no palette, no 16-bit                                                                  |
| Straight vs premultiplied model        | `colour_raster.d` (premult), `image.d` + `shading_test.d` (straight)            | SHIPPED, split convention   | "premultiplied RGBA region" vs "An image's texels are straight"                                                               |
| Image registry, generational handles   | `libs/ui/src/sparkles/ui/image.d`                                               | SHIPPED                     | `ImageRegistry`, `IMG3`, `ui.image.registry.*` tests                                                                          |
| Image pixel view type (stride, planes) | none; `ImageData.rgba` is a flat slice; font uses `ColourRegion` (data, stride) | absent                      | `ImageData`; `ColourRegion`; `terminal_view.painter.ImagePixels` (no stride, "no padding")                                    |
| Pixel formats beyond 8-bit RGBA        | `terminal_view.painter.PixelLayout` (gray to rgba, 8-bit)                       | SHIPPED (narrow)            | enum `PixelLayout`; `font` glyph coverage is 1 channel                                                                        |
| Cell-raster fallback (`GLY9`)          | `libs/ui/src/sparkles/ui/image_raster.d`                                        | SHIPPED                     | `imageRungOf`, `paintImageRaster`, tests `ui.imageRaster.*`                                                                   |
| Kitty graphics emit                    | `libs/tui/src/sparkles/tui/images.d`                                            | SHIPPED                     | `KittyImages`; raw RGBA f=32; no PNG, zlib or shared-memory transmission                                                      |
| Sixel emit                             | `libs/tui/src/sparkles/tui/sixel.d`                                             | SHIPPED                     | `writeSixel`; fixed 252-colour palette                                                                                        |
| iTerm2 inline images                   | `term_caps.d` enum member only                                                  | named, not implemented      | no `1337` emitter in any `.d` file                                                                                            |
| Kitty graphics receive (embedded term) | `libs/terminal-view/src/sparkles/terminal_view/{png_decoder,kitty_images}.d`    | SHIPPED                     | libghostty callback; 256 images, 320 MiB cap                                                                                  |
| Raylib texture upload                  | `libs/ui-raylib/src/sparkles/ui_raylib/image_textures.d`                        | SHIPPED                     | `ImageTextures`                                                                                                               |
| Vulkan texture upload                  | `libs/ui-vulkan/src/sparkles/ui_vulkan/{canvas,upload}.d`                       | SHIPPED                     | `R8G8B8A8_UNORM`, 16 MiB budget, `UVK29`/`UVK30`                                                                              |
| GPU-compressed textures (KTX2, BCn)    | none                                                                            | absent                      | no matches in code                                                                                                            |
| Image file viewer                      | `libs/doc-view/src/sparkles/doc_view/pane.d`                                    | SHIPPED, GUI only           | raylib `LoadTexture`, formats `png`, `gif`, `qoi`                                                                             |
| Markdown inline images in hue          | `docs/specs/hue/media.md`                                                       | PLANNED                     | all `IMG`/`MDB` rows `not started`                                                                                            |
| Colour glyph rendering                 | `libs/font/src/sparkles/font/{colr,bitmap,colour_raster}.d`                     | SHIPPED (`COLR` v0 only)    | module headers; `oracle.colour.*`                                                                                             |
| Golden screenshot A/B                  | `apps/hue/tools/gui-ab.d`, `HUE_GUI_SCREENSHOT`                                 | SHIPPED, byte equality      | `oldPng == newPng`; no perceptual metric, no tolerance                                                                        |
| PNG differential oracle                | `libs/ui-raylib/src/sparkles/ui_raylib/png_oracle.d`                            | SHIPPED                     | stb_image over `contrib/pngsuite` + `contrib/testpngs`, asserts more than 150 files                                           |
| Font differential oracle package       | `libs/font-oracle`                                                              | SHIPPED                     | HarfBuzz, FreeType, fontations goldens; manifest pins SHA-256                                                                 |
| Metadata explorer / `inspect`          | `docs/specs/font-explorer/`                                                     | SPECIFIED only              | `PLAN.md`: every area `not started`                                                                                           |
| Generic algorithms (resize, filter)    | `sampleArea` in `image_raster.d`; `rasterizeBitmapGlyph` area average           | SHIPPED, two private copies | not shared; two area-averaging routines                                                                                       |
| SIMD dispatch precedent                | `libs/base/src/sparkles/base/text/{simd_caps,utf8_simd,utf16_simd}.d`           | SHIPPED (text)              | `hasAvx512BwVl` etc., package-private                                                                                         |
| Async file reads                       | `libs/event-horizon/src/sparkles/event_horizon/io.d`, `vfs.d`                   | SHIPPED                     | `read(h, buf, offset)`; no image consumer                                                                                     |
| N-D arrays / DLPack / tensors          | none; `mir.ndslice` only recommended in prose                                   | absent                      | `docs/guidelines/functional-declarative-programming-guidelines.md` line 503 "Use `mir.ndslice` for any multidimensional data" |
| Video                                  | none                                                                            | absent                      | no code or spec                                                                                                               |

## Gaps and tensions

**G1. Two PNG decoders with different contracts, plus a third in draft (Q4, Q8, Q9).** `font.png` is `@nogc`, premultiplied, form-limited; `ui.png` allocates, is straight-alpha, form-complete. Neither checks chunk CRCs (both say so), which matters for a hostile-input codec but matches stb_image, the only oracle. The draft `sparkles:image` unifies both but is unmerged, so any image design must state which one it builds on. It is also the only existing `Expected`-typed codec result with file offsets.

**G2. No pixel view type (Q1, Q3, Q9).** Pixels travel as `const(ubyte)[]` plus a `Size` (`ImageData`), as `ColourRegion` (data plus `stride`) or as `ImagePixels` (width, height, `PixelLayout`, "no padding"). There are no strides in the registry, no planes (YUV, planar), no N-D, no sample types beyond 8-bit, no use of `mir.ndslice` although the functional-programming guideline tells authors to use it for "any multidimensional data". The guideline and the code disagree.

**G3. Alpha convention split (Q1, Q5).** Glyph colour regions are premultiplied; registry images are straight (`shading_test.d`); the Vulkan path then premultiplies in the shader (`UVK6`). `ImageData` does not document its convention. Any conversion step needs a declared state.

**G4. Colour is untyped (Q5).** No ICC, no transfer function tag, no colour primaries, no 16-bit or float; `ui.png` drops 16-bit to the high byte. PNG `gAMA`/`sRGB`/`iCCP`/`cICP` chunks are skipped as ancillary. `UVK6`/`UVK7` decide sRGB handling on the target, not the image.

**G5. Metadata is discarded (Q5, Q4).** Neither decoder surfaces ancillary chunks (`tEXt`, `eXIf`, `pHYs`). The font-explorer template wants typed inspection output (`inspect` as text or JSON) from the same library the app uses; images have no such report type.

**G6. Allocation policy in `ui.png` conflicts with standing rules (Q4).** `AGENTS.md` asks for `@nogc nothrow` where possible, Buffers over `appender`, writers over strings. `ui.png` uses `new ubyte[]`, `~=` and `.dup`; `encodePng` returns `ubyte[]` rather than writing to an output range. `font.png` shows the caller-storage shape that complies. Neither supports suspension or incremental feed: both need the whole file in memory and decode in one call.

**G7. Whole-file, single-shot, non-streaming (Q4, Q6).** Both decoders take the entire PNG. The event loop (`event-horizon`) offers offset reads but no image consumer; no progressive or tiled decode, no cancellation, no budget for time (only for bytes: `maxPngPixels`, `uploadBudget`). Hostile-input bounds are by declared size, not by work.

**G8. Upload path is RGBA8 only, linear sampler, per-frame byte budget (Q6, Q7).** `UVK24` fixes linear filtering and foreground-alpha multiply, so a general texture (mipmaps, array, compressed, YUV) would require a spec change. No GPU decompression, no staging reuse beyond `Uploads`, no direct file-to-GPU path. Raylib path uploads through `LoadTexture` on paths, bypassing the registry for `doc-view` (a separate decode with raylib's own stb_image).

**G9. Terminal protocol coverage (Q6).** Kitty emit sends raw RGBA base64 (large); no PNG passthrough, no shared-memory or file transmission, no animation frames; iTerm2 named, not drawn; sixel palette fixed. `CAP3` is `partial`.

**G10. Duplicated resampling (Q3).** `sampleArea` (cell raster) and `rasterizeBitmapGlyph` (strike scaling) each implement area-weighted averaging privately. This is exactly the "no package-local copies of shared infra" tension from `AGENTS.md`: a generic image algorithm layer would absorb both.

**G11. Oracles are single-purpose and byte-exact (Q8).** `png_oracle.d` uses stb_image through raylib; the font oracle uses HarfBuzz/FreeType/fontations ImportC. Neither generalises: there is no image-oracle package, no corpus for JPEG/WebP/etc., no tolerance-based comparison (PSNR, SSIM, ULP), no fuzz harness, no coverage of PNG conformance beyond PngSuite (`libpng-src` flake input `v1.6.44`). Golden diffs in hue are byte equality of PNGs, which a decoder or encoder change can break without any visible change.

**G12. Portability constraints are unmeasured for images (Q2, Q3, Q9).** `@betterC`, `--wasm` and Android builds are standing targets in `AGENTS.md`; `font.png` is `nothrow @nogc` and plausibly suited, but whether any image code is exercised under those modes is not verified. `sparkles.font.png` casts a `@system` zlib call to `pure` (`@trusted`), a pattern a larger codec family would have to repeat or centralise. Phobos zlib is the only inflate; no deflate-level control exists in `encodePng` (`std.zlib.compress`, GC-allocating).

**G13. SIMD and GPU dispatch exists only for text (Q3, Q7).** Capability flags in `simd_caps.d` are `package` visibility and x86-LDC only; there is no public dispatch facility an image kernel could use, and no compute-shader image kernel (the shader sources in `libs/ui/shaders/effects.d` are for effects). No break-even measurements exist.

**G14. No consumer-side contracts for video, tensors or robotics (Q1, Q6, Q9).** There is no frame/timestamp model, no demux abstraction, no DLPack-compatible layout; the nearest ownership precedents are `Handle`/`Pool` (generational, fixed capacity), `UniqueBuffer`, and `ImageRegistry`'s borrowed-bytes bargain.

### Consumers mapped to what exists

| Consumer                           | Exists today                                                                              | Missing                                                                 |
| ---------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Hue image viewer                   | `doc-view` image pane (raylib, `png`/`gif`/`qoi`, GUI); markdown placeholder              | Any non-raylib decode; TUI viewer; JPEG/WebP; diff view (`IMG5` of hue) |
| Terminal graphics                  | Kitty raw, sixel, cell ladder, receive via libghostty                                     | iTerm2; PNG/shm transmission; animation; downscale before send          |
| GPU textures (KTX2/Basis)          | RGBA8 registry upload                                                                     | Everything: container, transcode, formats, mips, array layers           |
| Golden-screenshot diffing          | `HUE_GUI_SCREENSHOT`, `gui-ab` byte compare, `tui-ab` pty bytes                           | Tolerant image comparison, diff image output, shared helper             |
| Metadata explorer                  | font-explorer spec template; `font` inspection (`oracle` `inspection.d`)                  | An image/video report type; no code                                     |
| Scientific N-D                     | none                                                                                      | N-D view, sample types, TIFF/FITS-style formats                         |
| DLPack / ML tensors                | none                                                                                      | Layout descriptor with strides and dtype                                |
| Video editor / ffmpeg-like GPU CLI | none (CLI parsing exists in `core-cli`; GPU in `vulkan`, `ui-vulkan`)                     | Everything                                                              |
| 3D-engine embedding                | Vulkan loader and device in `vulkan`/`vulkan-wsi`; texture upload only inside `ui-vulkan` | A reusable upload/format layer outside the UI canvas                    |
| Spatial / robotics                 | none                                                                                      | Depth/point-cloud formats, timestamps                                   |

### Test-oracle and corpus precedents

- `libs/font-oracle` (README, `dub.sdl`): test-only `sourceLibrary`; HarfBuzz declared by ImportC; corpora through dev-shell variables (`$SPARKLES_FONTS_PATH`, `$SPARKLES_FONT_TEST_CORPUS`, `$SPARKLES_FLAKE_INPUT_HARFBUZZ_SRC`, opt-in `$SPARKLES_FONT_UNFREE_CORPUS`); a `manifest.txt` pins every face by SHA-256 with licence and source (`oracle.corpus.manifest`); goldens generated by D tools (`libs/font-oracle/tools/gen_*_goldens.d`); tests skip when the corpus is unset. This is the template for an image-oracle package.
- `png_oracle.d`: asserts `SPARKLES_FLAKE_INPUT_LIBPNG_SRC` is set (flake input `libpng-src`, `github:pnggroup/libpng/v1.6.44`), asserts the corpus has more than 150 files, compares byte for byte, and reports files only one side decodes. The AGENTS.md rule "have the test assert the var is set" is followed here, while the font oracle skips; the two precedents differ on missing-corpus policy.
- `oracle.colour.layersAndPalettes` and `oracle.colour.strikes` check `COLR`, `CPAL`, `CBDT`, `sbix` against HarfBuzz API results.
- `terminal_view.protocol_oracle`: "The oracle is the authorities, not our encoder": byte sequences transcribed from specifications, never produced by the code under test. A strong rule for protocol and bitstream tests.
- Hue A/B tools: reproducibility-before-comparison and "builds must differ" guards.

## Questions for the design grill

These are open decisions this area forces. None is decided here.

1. **Which PNG codec is the base, and does `ui.png`'s "decode as stb_image does" rule (no CRC check) stay the contract?** (Q4, Q8)
   - A. Build on draft `sparkles:image` as is (stb_image parity, CRC unchecked).
   - B. Same, but add an opt-in strict mode (CRC, ancillary-chunk validation) behind a flag.
   - C. Strict by default with a lenient flag, breaking parity with the current oracle.
   - Recommendation: B; the oracle and consumers keep working, hostile-input users opt in.

2. **What is the pixel type: one struct or a family?** (Q1, Q2, Q9)
   - A. A strided 2-D view over bytes with a runtime format tag (like `ImagePixels` plus stride).
   - B. A compile-time parameterised view (element type, layout), adopting or wrapping `mir.ndslice`.
   - C. B for algorithms, A as the erased interchange type at plugin and GPU boundaries.
   - Recommendation: C; it keeps the registry and protocol seams simple while letting kernels specialise.

3. **Where is the alpha and colour state recorded?** (Q1, Q5)
   - A. In the type (straight and premultiplied are distinct types).
   - B. In a runtime descriptor beside the pixels (alpha mode, transfer, primaries).
   - C. Convention only (always straight at interchange, premultiply at the edge as today).
   - Recommendation: B for interchange, A inside algorithms that need it.

4. **How are generic interfaces expressed?** (Q2)
   - A. Design by introspection (capability traits, shell-with-hooks) as in the repo guidelines.
   - B. Runtime vtables or tagged unions for codecs, DbI for algorithms.
   - C. Extern(C) seams like the test runner's shim-and-impl split.
   - Recommendation: B for the codec registry (formats are discovered at run time), A inside algorithms; defer C until a plugin story is demanded.

5. **Incremental decode: push, pull or coroutine?** (Q4, Q6)
   - A. Push parser (feed bytes, get rows), explicit state struct, caller-owned scratch.
   - B. Pull through event-horizon effects with suspension.
   - C. Whole-file only, add incremental later.
   - Recommendation: A with a state struct that B can drive; C repeats today's G7 and makes video impossible.

6. **Package boundaries.** (Q9)
   - A. `image-core` (view, format tags, errors), `image-formats`, `image-algorithms`, plus `video`.
   - B. One `image` package with submodules until a second consumer needs a cut.
   - C. Core in `base`, codecs per package.
   - Recommendation: A, because `ui`, `font` and `terminal-view` should depend on the core without the codecs (the same reason `font.png` should not pull `ui`).

7. **Oracle policy: assert or skip when a corpus is missing?** (Q8)
   - A. Assert (`png_oracle` style); fails outside `nix develop`.
   - B. Skip via `skipTest` (font-oracle style).
   - C. Assert on CI, skip locally.
   - Recommendation: C, driven by an environment flag; AGENTS.md says to assert for pinned flake inputs and skip for derived outputs.

8. **GPU upload ownership.** (Q6, Q7)
   - A. Stay inside `ui-vulkan` and grow it.
   - B. Extract an upload and texture-format layer usable by 3D embedding and video.
   - C. Image library produces ready-to-copy staging blocks and knows nothing about Vulkan.
   - Recommendation: C feeding B, so `UVK29`/`UVK30` remain the UI canvas's concern.

9. **Which tolerance model for golden and differential image tests?** (Q8)
   - A. Byte equality only (today).
   - B. Per-test tolerance (max channel delta, count of differing pixels) plus a written diff image.
   - C. Perceptual metrics (SSIM-class).
   - Recommendation: A for lossless codecs, B for resampling and lossy formats; leave C unless a lossy codec demands it.

## Sources

Code read on this branch: [`libs/font/src/sparkles/font/png.d`][font-png], [`bitmap.d`][font-bitmap], [`colour_raster.d`][font-colour], [`colr.d`][font-colr]; [`libs/ui/src/sparkles/ui/png.d`][ui-png], [`image.d`][ui-image], [`image_raster.d`][ui-raster]; [`libs/ui-raylib/src/sparkles/ui_raylib/png_oracle.d`][png-oracle], [`image_textures.d`][ray-tex]; [`libs/tui/src/sparkles/tui/images.d`][tui-images], [`sixel.d`][tui-sixel]; [`libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d`][grid-canvas]; [`libs/terminal-view/src/sparkles/terminal_view/png_decoder.d`][tv-png]; [`libs/ui-vulkan/src/sparkles/ui_vulkan/canvas.d`][vk-canvas]; [`libs/doc-view/src/sparkles/doc_view/pane.d`][docview-pane]; [`libs/base/src/sparkles/base/term_caps.d`][term-caps]; [`apps/hue/tools/gui-ab.d`][gui-ab]; [`libs/font-oracle`][font-oracle] (its `README.md`); flake input `libpng-src` in [`flake.nix`][flake].

Specs and guides: [`docs/specs/ui/effects.md`][spec-effects], [`docs/specs/design-system/glyphs.md`][spec-glyphs], [`capabilities.md`][spec-caps], [`decisions.md`][spec-ds-decisions], [`docs/specs/font/SPEC.md`][spec-font], [`docs/specs/ui-vulkan/SPEC.md`][spec-vk], [`docs/specs/hue/media.md`][spec-hue-media], [`docs/specs/hue/gui.md`][spec-hue-gui], [`docs/specs/font-explorer/SPEC.md`][spec-fexp], [`docs/research/binary-formats/comparison.md`][bf-comparison], [`docs/guidelines/research-docs.md`][research-docs].

Draft (read through git, not checked out): commit `5c711097f` (`feat(image): a PNG codec library`), `15048a682`, `672888e9f` on branch `refactor/image-png`.

<!-- References -->

[font-png]: ../../../../libs/font/src/sparkles/font/png.d
[font-bitmap]: ../../../../libs/font/src/sparkles/font/bitmap.d
[font-colour]: ../../../../libs/font/src/sparkles/font/colour_raster.d
[font-colr]: ../../../../libs/font/src/sparkles/font/colr.d
[ui-png]: ../../../../libs/ui/src/sparkles/ui/png.d
[ui-image]: ../../../../libs/ui/src/sparkles/ui/image.d
[ui-raster]: ../../../../libs/ui/src/sparkles/ui/image_raster.d
[png-oracle]: ../../../../libs/ui-raylib/src/sparkles/ui_raylib/png_oracle.d
[ray-tex]: ../../../../libs/ui-raylib/src/sparkles/ui_raylib/image_textures.d
[tui-images]: ../../../../libs/tui/src/sparkles/tui/images.d
[tui-sixel]: ../../../../libs/tui/src/sparkles/tui/sixel.d
[grid-canvas]: ../../../../libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d
[tv-png]: ../../../../libs/terminal-view/src/sparkles/terminal_view/png_decoder.d
[vk-canvas]: ../../../../libs/ui-vulkan/src/sparkles/ui_vulkan/canvas.d
[docview-pane]: ../../../../libs/doc-view/src/sparkles/doc_view/pane.d
[term-caps]: ../../../../libs/base/src/sparkles/base/term_caps.d
[gui-ab]: ../../../../apps/hue/tools/gui-ab.d
[font-oracle]: ../../../../libs/font-oracle/dub.sdl
[flake]: ../../../../flake.nix
[spec-effects]: ../../../specs/ui/effects.md
[spec-glyphs]: ../../../specs/design-system/glyphs.md
[spec-caps]: ../../../specs/design-system/capabilities.md
[spec-ds-decisions]: ../../../specs/design-system/decisions.md
[spec-font]: ../../../specs/font/SPEC.md
[spec-vk]: ../../../specs/ui-vulkan/SPEC.md
[spec-hue-media]: ../../../specs/hue/media.md
[spec-hue-gui]: ../../../specs/hue/gui.md
[spec-fexp]: ../../../specs/font-explorer/SPEC.md
[bf-comparison]: ../../binary-formats/comparison.md
[research-docs]: ../../../guidelines/research-docs.md
