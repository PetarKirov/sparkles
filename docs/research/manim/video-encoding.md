# Video Encoding (frames → file/stream)

How a stream of rendered RGBA frames becomes a playable video file — the encode
path a native animation engine chooses once its [rasteriser][c-raster] has
[read a frame back][c-capture] into an addressable buffer.

This cluster answers analysis-spine **axis 5** (output & encoding) in full: once
the backend hands you an RGBA framebuffer, four integration styles turn it into
an `.mp4`/`.webm`/`.mov` — a piped **ffmpeg** subprocess, the **libav\*** C
libraries called in-process, the **GStreamer** pipeline framework, or a
directly-linked single-codec encoder (**SVT-AV1**) with a hand-written
container. It also touches **axis 8**: a byte-reproducible encode is what lets an
engine [content-hash][c-cache] each unit of work and skip re-rendering, and the
partial-file-per-`play()` scheme both Manim forks use is the physical substrate
of that cache. The axis-5 vocabulary — [codec, muxing, and pixel
format][c-codec]; [frame capture and readback][c-capture]; [color model and
gamma][c-color] — is defined once in [`concepts.md`][c-codec] and referenced here.

**Last reviewed:** July 11, 2026

| Approach                                                     | Integration                              | Language/API                                           | License                                | Pixfmt in                                | Codecs / container                                     | Determinism                                     | Bindable from D via                                                           |
| ------------------------------------------------------------ | ---------------------------------------- | ------------------------------------------------------ | -------------------------------------- | ---------------------------------------- | ------------------------------------------------------ | ----------------------------------------------- | ----------------------------------------------------------------------------- |
| [**ffmpeg (CLI subprocess)**](#ffmpeg-cli-subprocess)        | subprocess, raw stdin pipe (zero ABI)    | `ffmpeg` CLI argv                                      | LGPL-2.1+ (GPL if `libx264`/GPL parts) | `-f rawvideo -pix_fmt rgba` (or `rgb32`) | `libx264`/`libx264rgb`/`libvpx-vp9` → mp4/webm/mov     | byte-repro when the binary + options are pinned | `std.process` / `sparkles:core-cli` — **no bindings**                         |
| [**libav\* via the C API**](#libav-via-the-c-api-in-process) | linked C libraries, in-process           | C: `libavcodec`/`libavformat`/`libavutil`/`libswscale` | LGPL-2.1+ (GPL if GPL codecs linked)   | `AVFrame`; `sws_scale` RGBA→`yuv420p`    | every muxer/encoder the build carries                  | same as ffmpeg — pin the library build          | **ImportC** + pkg-config (like `libs/ghostty`); PyAV is the reference wrapper |
| [**GStreamer**](#gstreamer)                                  | pipeline framework, `appsrc` push        | C: GLib/GObject                                        | LGPL (core + base plugins)             | `appsrc` caps `video/x-raw,format=RGBA`  | encoder/muxer elements (`x264enc`, `vp9enc`, `av1enc`) | pipeline- and element-version dependent         | ImportC of GLib/GObject/`gst` — **large surface** (advised against)           |
| [**SVT-AV1 direct / IVF**](#svt-av1-direct--ivf)             | linked single-codec lib, hand-muxed file | C: `EbSvtAv1Enc.h`                                     | BSD-3-Clause-Clear (© AOM)             | `EbBufferHeaderType` planar YUV 4:2:0    | **AV1 only** → IVF (`DKIF`/`AV01`)                     | encoder-deterministic per build/preset          | ImportC (small header) — but you own muxing + RGB→YUV                         |

> [!NOTE]
> The first two rows are the same software seen from two sides. `ffmpeg` the
> program is a thin CLI over the `libav*` libraries; piping to it (row 1) and
> linking them (row 2) share codecs, containers, and licensing, and differ only
> in **where the process boundary sits**. Rows 3–4 are genuinely different stacks.

---

## ffmpeg (CLI subprocess)

The lowest-friction path, and the one **ManimGL** takes: spawn `ffmpeg`, tell it
the frames are headerless raw RGBA, and write the framebuffer bytes to its
stdin. There is **zero ABI surface** — the only contract is an argv and a byte
stream — so a version mismatch can never corrupt the host process, and the
dependency is a binary on `PATH`, not a linked library.

### The raw-RGBA pipe

The [rawvideo demuxer][ffmpeg-formats] is what makes this work: it accepts a
bare stream of pixels with no container framing. Its own documentation states the
contract ([ffmpeg-formats.html][ffmpeg-formats]):

> _"Raw video demuxer. This demuxer allows one to read raw video data. … Since
> there is no header specifying the assumed video parameters, the user must
> specify them in order to be able to decode the data correctly."_

So the caller supplies frame geometry, pixel format, and rate on the command
line, then streams frames. ManimGL's `SceneFileWriter.open_movie_pipe` assembles
exactly that argv and launches it with `subprocess.Popen(..., stdin=PIPE)`
([`scene_file_writer.py`][gl-writer], pinned `e61ad5c3`):

```bash
ffmpeg -y -f rawvideo -s {W}x{H} -pix_fmt rgba -r {fps} -i - \
       -vf vflip,eq=saturation={s}:gamma={g} -an -loglevel error \
       -vcodec libx264 -pix_fmt yuv420p out.mp4
```

`-i -` reads frames from the pipe; each `write_frame` reads the FBO back with
`camera.get_raw_fbo_data()` and writes the raw `rgba` bytes to the process's
stdin ([`camera.py`][gl-camera]). Its constructor defaults are `ffmpeg_bin =
"ffmpeg"`, `video_codec = "libx264"`, `pixel_format = "yuv420p"`, extension
`.mp4`; `use_fast_encoding()` swaps in a **lossless** RGB path —
`video_codec = "libx264rgb"`, `pixel_format = "rgb32"` — which skips YUV chroma
subsampling entirely ([`scene_file_writer.py`][gl-writer]). The vertical flip and
a `eq=saturation:gamma` [color][c-color] tweak are folded into the `-vf` filter,
i.e. applied by the encoder at the pixel boundary rather than in-shader. The
[`frame-capture.d`][ex-capture] probe stands in for the readback step and ends by
noting these bytes are "the input to `ffmpeg -f rawvideo -pix_fmt rgba`".

**Codecs and containers** are whatever the `ffmpeg` build carries: H.264 via
`libx264`, lossless RGB H.264 via `libx264rgb`, VP9 via `libvpx-vp9`, muxed into
`.mp4`/`.webm`/`.mov` by extension. **Licensing** follows the binary: FFmpeg is
"licensed under the GNU Lesser General Public License (LGPL) version 2.1 or
later", but "FFmpeg incorporates several optional parts … covered by the …
(GPL) … If those parts get used the GPL applies to all of FFmpeg"
([legal.html][ffmpeg-legal]) — and `libx264` is one such GPL part, so a typical
H.264 build is effectively GPL.

**Determinism** is a function of the pinned binary: the RGBA bytes are already
deterministic (a CPU rasteriser is the [reproducibility oracle][c-detsample]),
and the encode is a pure function of (bytes, encoder build, options). Byte-identical
video therefore requires pinning the `ffmpeg` build **and** constraining
threading (frame-parallel `libx264` can perturb output); this is why the RGB-lossless
path is attractive for regression snapshots. Crucially, the [content-hash
cache][c-cache] keys on the render _inputs_, not the encoded bytes, so caching is
correct even where the encoder is not bit-stable.

**D-bindability** is trivial: there is nothing to bind. `std.process.pipeProcess`
or `sparkles:core-cli`'s process utilities spawn `ffmpeg` and feed its stdin; the
repo's `apps/terminal` already spawns and drives subprocesses this way.

---

## libav\* via the C API (in-process)

The same encoders, minus the subprocess: link `libavcodec` (codecs),
`libavformat` (muxers), `libavutil` (`AVFrame`/pixel-format enums), and
`libswscale` (pixel conversion), and drive them through their C API. No pipe, no
external binary — the frame never leaves the process — at the cost of a real ABI
surface to bind and keep in sync.

The encode loop is three C calls. First convert RGBA to the codec's planar YUV
with **`sws_scale`** — libswscale bills itself as a "Color conversion and scaling
library" and the call is documented ([`swscale.h`][swscale-h], pinned `n8.1`):

> _"Scale the image slice in srcSlice and put the resulting scaled slice in the
> image in dst."_

Then hand the `AVFrame` to the encoder with **`avcodec_send_frame`**
([`avcodec.h`][avcodec-h]):

> _"Supply a raw video or audio frame to the encoder. Use
> avcodec_receive_packet() to retrieve buffered output packets."_

`int avcodec_send_frame(AVCodecContext *avctx, const AVFrame *frame);` — a
`NULL` frame flushes the encoder. Finally mux each output packet into the
container with **`av_interleaved_write_frame`** ([`avformat.h`][avformat-h]):

> _"Write a packet to an output media file ensuring correct interleaving."_

`int av_interleaved_write_frame(AVFormatContext *s, AVPacket *pkt);` — it buffers
packets internally to keep DTS monotonic, which a hand-rolled muxer must
otherwise handle.

**PyAV is the reference binding pattern.** Manim community wraps exactly these
libraries through [PyAV][pyav] (`import av`, BSD-3-Clause, latest `v18.0.0`), and
its `SceneFileWriter` shows the idiomatic shape: **one partial movie file per
`play()`**, each an independent container opened by `open_partial_movie_stream`,
with frames pushed as `av.VideoFrame.from_ndarray(frame, format="rgba")`
([`scene_file_writer.py`][mc-writer], pinned `4d25c031`). `from_ndarray` is
documented "Construct a frame from a numpy array" and its implementation branches
on `rgba`, `rgb24`, `yuv420p`, `yuva444p`, and dozens more
([`frame.py`][pyav-frame-src]) — so RGBA-in is a first-class case, not a
work-around. The codec/pixel-format choice is by extension:

| Output              | Codec        | Pixel format |
| ------------------- | ------------ | ------------ |
| default `.mp4`      | `libx264`    | `yuv420p`    |
| `.webm`             | `libvpx-vp9` | `yuv420p`    |
| `.webm` transparent | `libvpx-vp9` | `yuva420p`   |
| transparent `.mov`  | `qtrle`      | `argb`       |

`[source-verified]` ([`scene_file_writer.py:552-566`][mc-writer]). At `finish()`,
`combine_files` re-opens an FFmpeg concat list with `av.open(str(file_list),
format="concat")` to produce the final video — the [partial-file
concat][c-cache] that turns cached clips into one movie.

**Licensing** is FFmpeg's (LGPL-2.1+, GPL if GPL encoders are linked in), and
PyAV itself adds a BSD-3-Clause wrapper. **Determinism** matches the CLI path —
same encoders, so pin the library build.

**D-bindability** is the standout: these are plain C headers reachable by
**ImportC**. The repo already does this for a C VT engine — `libs/ghostty` is a
`sourceLibrary` whose `c.c` shim `#include`s the vendored header and whose Nix/dub
wiring routes `pkg-config --cflags` into ImportC (the `sourceLibrary`-target
requirement is a documented gotcha). `libavcodec`/`libavformat`/`libavutil`/
`libswscale` all ship `.pc` files, so the same recipe — a `c.c` that includes
`<libavcodec/avcodec.h>` etc., `targetType "sourceLibrary"`, pkg-config `libs` —
gives an in-process encoder with no subprocess. The `AVFrame`/`AVCodecContext`
structs are large but stable; PyAV is the working proof that a high-level binding
over them is maintainable.

> [!NOTE]
> The libav\* names have a history: after the 2011 `libav`/FFmpeg fork the same
> symbols (`avcodec_*`, `av_*`) lived in both trees; today the maintained provider
> is **FFmpeg**, and PyAV, GStreamer's `libav` plugin, and Chromium all build on
> FFmpeg's `libav*`. Bind against FFmpeg's headers, not the abandoned `libav`
> project's.

---

## GStreamer

[GStreamer][gst] is a general **pipeline-based multimedia framework**: media flows
through a graph of typed elements (sources, converters, encoders, muxers, sinks)
that negotiate capabilities ("caps") at their pads. To feed it rendered frames
you push buffers into an **`appsrc`** element at the head of a pipeline like
`appsrc ! videoconvert ! x264enc ! mp4mux ! filesink`. The element is documented
([appsrc][gst-appsrc]):

> _"The appsrc element can be used by applications to insert data into a
> GStreamer pipeline. Unlike most GStreamer elements, Appsrc provides external API
> functions."_

The application sets `appsrc`'s caps (e.g. `video/x-raw,format=RGBA,width=…`) and
pushes each frame as a `GstBuffer` via the `push-buffer` action signal;
`videoconvert` handles the [RGBA→YUV][c-codec] conversion, the encoder element
compresses, the muxer containerises, and `filesink` writes. It is **LGPL** —
"GStreamer is a plugin-based framework licensed under the LGPL" and "We require
that all code going into our core packages is LGPL" ([licensing][gst-license]);
`appsrc` lives in the LGPL `gst-plugins-base` package. Current stable is the
**1.26** series (`1.26.11`, March 2026).

**Recommended against for this use case.** GStreamer is built for _dynamic,
negotiated, multi-stream_ media graphs — live pipelines, format renegotiation,
clock synchronisation, dynamic pad linking — none of which a deterministic
"RGBA frames → one encoder → one file" path needs. The costs are concrete:

- **A large, framework-shaped dependency.** GLib + GObject's runtime type system,
  a plugin registry, and caps negotiation sit between your bytes and the encoder —
  where the [ffmpeg subprocess](#ffmpeg-cli-subprocess) is a single argv and a pipe.
- **Indirection over control.** The encode is expressed as a pipeline string and
  signal handlers, not a straight-line `send_frame`/`write_frame` loop, making the
  exact codec settings and the [determinism](#libav-via-the-c-api-in-process)
  story harder to pin down than a fixed `ffmpeg` command line.
- **Binding surface.** ImportC _can_ consume the GLib/GObject/`gst` headers, but
  that pulls the whole GObject macro-and-vtable idiom (`g_object_new`,
  `GType`, signal marshalling) into D — far more than the flat `libav*` C API, for
  no codec that FFmpeg does not already provide.

> [!WARNING]
> No surveyed animation engine reaches for GStreamer to write its render output —
> the field splits between the piped `ffmpeg` subprocess (ManimGL) and the linked
> `libav*` libraries (Manim community's PyAV). GStreamer earns its keep in
> _capture/streaming/playback_ applications, not in a batch frame-encoder. Treat
> it as a documented non-choice.

---

## SVT-AV1 direct & IVF

At the far end of the integration spectrum sits linking a **single codec library
directly** and writing the container by hand — no ffmpeg, no libav\*, no
framework. **MathAnimation** is the survey's example: it links Intel/Netflix's
[SVT-AV1][svtav1] encoder and hand-muxes an IVF file.

SVT-AV1 describes itself as an "AV1-compliant software encoder library" whose
work "targets the development of a production-quality AV1-encoder"
([README][svtav1-readme]); it is **BSD-3-Clause-Clear** (© Alliance for Open
Media, [LICENSE.md][svtav1-license]), latest stable **`v4.1.0`**. Its C API is a
five-step handle→config→picture→packet loop ([`EbSvtAv1Enc.h`][svtav1-api]):
`svt_av1_enc_init_handle` ("Call the library to construct a Component Handle"),
`svt_av1_enc_send_picture` ("Send the picture"), and `svt_av1_enc_get_packet`,
whose brief is literally:

> _"Step 5: Receive packet."_

MathAnimation drives exactly those calls: it renders at a fixed 60 fps, runs a
**GPU RGB→YUV 4:2:0** shader pass, does an async PBO [readback][c-capture], feeds
`encoder->pushYuvFrame(...)`, and encodes on a worker thread at `crf 28`,
`preset 12`, `color-format 420`, `input-depth 8`
([`Encoder.cpp`][ma-encoder], pinned `4b2bace5`). Because SVT-AV1 emits a bare AV1
elementary stream, MathAnimation **writes the container itself** — an IVF header
built byte-by-byte:

```cpp
unsigned char header[32] = { 'D','K','I','F', 0,0,32,0, 'A','V','0','1' };  // IVF, not MP4
```

This is the whole trade of the far end: the smallest possible dependency (one
codec, one header) and full control of the bitstream, paid for with **no
container/codec choice** (AV1-in-IVF only) and **owning the muxer and the RGB→YUV
conversion** that `libav*`/`ffmpeg` would do for you.

> [!WARNING]
> The MathAnimation output is **mislabelled**: the container is IVF/AV1 but the
> export dialog names the file `.mov` (`filepath.replace_extension(".mov")`), and
> the README advertises `.mp4` — a `.mov`-named file that actually holds an IVF
> AV1 stream. Its hardware path is also a **0-byte stub**
> ([`NvidiaEncoder.cpp`][ma-nvenc]). A direct-encoder design must own container
> correctness end-to-end; there is no ffmpeg to get the muxing right.

**D-bindability** is good in the small — `EbSvtAv1Enc.h` is a compact C header,
ImportC-friendly by the same `libs/ghostty` recipe — but the surrounding work
(a correct IVF/MP4 muxer, a color-correct RGBA→YUV converter) is exactly what
the libav\* path hands you for free. It is the right choice only if AV1-only
output and a minimal dependency graph outrank container/codec breadth.

---

## Pixel-format & color-range gotchas

Every path above crosses the same [RGBA → codec pixel format][c-codec] boundary,
and it is where correctness quietly leaks:

- **`yuv420p` is limited-range and chroma-subsampled.** The default `yuv420p`
  (the pixel format both ManimGL and Manim community write) is 4:2:0 — chroma at
  quarter resolution — and, by ffmpeg convention, _limited_ range (luma 16–235)
  rather than full range (`yuvj420p` / an explicit `color_range`). Feeding
  full-range RGBA into a limited-range target without saying so crushes contrast
  at the extremes. The clean escape is to avoid YUV altogether: ManimGL's
  `use_fast_encoding()` switches to `libx264rgb`/`rgb32`, a lossless full-RGB
  path with no chroma loss and no range ambiguity ([`scene_file_writer.py`][gl-writer]).

- **Premultiplied vs straight alpha.** A frame's alpha convention
  ([color model][c-color]) must match what the encoder expects; blending
  premultiplied colors as if straight (or vice-versa) produces dark or bright
  fringes at edges. Composite in the convention the pixel format documents.

- **WebM/MOV alpha is a different pixel format, not a flag.** Transparency needs
  an alpha-carrying format: Manim community selects `yuva420p` with `libvpx-vp9`
  for a transparent `.webm`, and `qtrle`/`argb` for a transparent `.mov`
  ([`scene_file_writer.py:562-566`][mc-writer]) — you cannot get alpha out of a
  plain `yuv420p` mp4.

- **Color tweaks at the encode boundary.** ManimGL folds a
  `eq=saturation:gamma` pass into ffmpeg's `-vf` ([`scene_file_writer.py`][gl-writer]) —
  a reminder that the encoder is the last place [gamma][c-color] gets touched, so
  a linear-vs-sRGB mistake upstream is baked in here.

---

## Recommendation for a hybrid D engine

Take both integration styles, in order:

1. **Ship the ffmpeg subprocess first (the ManimGL model).** Pipe raw RGBA to
   `ffmpeg -f rawvideo -pix_fmt rgba -i - …` over stdin. It has **zero ABI
   surface**, needs no bindings (`std.process` / `sparkles:core-cli` already spawn
   and drive subprocesses, as `apps/terminal` shows), and gives every codec and
   container for free. Pin the `ffmpeg` build for [reproducible][c-detsample]
   output, and offer the `libx264rgb`/`rgb32` lossless path for regression
   snapshots. This is also what external users can run without linking anything.

2. **Add in-process libav\* via ImportC later, when the pipe is the bottleneck.**
   Bind `libavcodec`/`libavformat`/`libavutil`/`libswscale` with the same
   pkg-config + `sourceLibrary` ImportC recipe `libs/ghostty` uses, and run the
   `sws_scale` → `avcodec_send_frame` → `av_interleaved_write_frame` loop with no
   subprocess. **PyAV is the reference wrapper** to mirror — including its
   one-partial-file-per-`play()` scheme. Keep the subprocess path as the portable
   fallback.

3. **Skip GStreamer.** Its dynamic-pipeline framework buys nothing a fixed
   RGBA→encoder→mux path needs, and its GLib/GObject binding surface dwarfs the
   flat `libav*` C API for no additional codec.

4. **Skip direct-single-codec-linking (SVT-AV1/IVF) unless AV1-only is a hard
   requirement.** MathAnimation's minimal-dependency win comes with owning the
   muxer and the RGB→YUV conversion — and the mislabelled-container hazard shows
   the downside. `libav*` gives AV1 (and everything else) with correct muxing.

5. **Structure output for [caching][c-cache] from day one.** Emit **one partial
   file per `play()`**, key each on a [content hash][c-cache] of its render inputs
   (the [`frame-capture.d`][ex-capture] checksum illustrates the hash a cache keys
   on), reuse the file on a hit, and **concat** the partials into the final video.
   This is independent of which encoder path you pick, and it — not encoder
   bit-stability — is what makes iteration fast.

---

## Sources

- **ffmpeg CLI** — [rawvideo demuxer][ffmpeg-formats] (headerless-stream
  contract), [legal.html][ffmpeg-legal] (LGPL-2.1+/GPL), and ManimGL's
  [`scene_file_writer.py`][gl-writer] / [`camera.py`][gl-camera] (the exact argv,
  `libx264rgb`/`rgb32` lossless path; pinned `e61ad5c3`).
- **libav\* C API** — FFmpeg headers pinned `n8.1`: [`avcodec.h`][avcodec-h]
  (`avcodec_send_frame`), [`avformat.h`][avformat-h] (`av_interleaved_write_frame`),
  [`swscale.h`][swscale-h] (`sws_scale`). Reference binding: [PyAV][pyav]
  (`v18.0.0`, BSD-3-Clause) — [`frame.py`][pyav-frame-src] (`from_ndarray`
  formats) and Manim community's [`scene_file_writer.py`][mc-writer]
  (`from_ndarray(format="rgba")`, codec table, `concat`; pinned `4d25c031`).
- **GStreamer** — [appsrc][gst-appsrc] (push-based insertion),
  [licensing][gst-license] (LGPL core), version 1.26.
- **SVT-AV1 / IVF** — [README][svtav1-readme] ("AV1-compliant software encoder
  library"), [`EbSvtAv1Enc.h`][svtav1-api] (five-step C API),
  [LICENSE.md][svtav1-license] (BSD-3-Clause-Clear, `v4.1.0`), and MathAnimation's
  [`Encoder.cpp`][ma-encoder] / [`NvidiaEncoder.cpp`][ma-nvenc] (direct encode,
  hand-muxed `DKIF`/`AV01` IVF, NVENC stub; pinned `4b2bace5`).
- The [`frame-capture.d`][ex-capture] probe — the render → readback → checksum
  step this page's encoders consume.

<!-- References -->

[c-codec]: ./concepts.md#codec-muxing-and-pixel-format
[c-capture]: ./concepts.md#frame-capture-and-readback
[c-color]: ./concepts.md#color-model-and-gamma
[c-detsample]: ./concepts.md#deterministic-frame-sampling
[c-cache]: ./concepts.md#content-hash-caching
[c-raster]: ./concepts.md#rasterization
[ex-capture]: ./examples/frame-capture.d
[ffmpeg-formats]: https://ffmpeg.org/ffmpeg-formats.html
[ffmpeg-legal]: https://www.ffmpeg.org/legal.html
[avcodec-h]: https://github.com/FFmpeg/FFmpeg/blob/9047fa1b084f76b1b4d065af2d743df1b40dfb56/libavcodec/avcodec.h
[avformat-h]: https://github.com/FFmpeg/FFmpeg/blob/9047fa1b084f76b1b4d065af2d743df1b40dfb56/libavformat/avformat.h
[swscale-h]: https://github.com/FFmpeg/FFmpeg/blob/9047fa1b084f76b1b4d065af2d743df1b40dfb56/libswscale/swscale.h
[pyav]: https://pyav.org/docs/stable/
[pyav-frame-src]: https://github.com/PyAV-Org/PyAV/blob/54a4395bb4cdd9cdd53ff6216c50b69f6475c13d/av/video/frame.py
[gl-writer]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/scene/scene_file_writer.py
[gl-camera]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/camera/camera.py
[mc-writer]: https://github.com/ManimCommunity/manim/blob/4d25c031ffe71c602e20935afd54a96f33545a6e/manim/scene/scene_file_writer.py
[gst]: https://gstreamer.freedesktop.org/
[gst-appsrc]: https://gstreamer.freedesktop.org/documentation/app/appsrc.html
[gst-license]: https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/licensing.html
[svtav1]: https://gitlab.com/AOMediaCodec/SVT-AV1
[svtav1-readme]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/README.md
[svtav1-api]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Source/API/EbSvtAv1Enc.h
[svtav1-license]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/LICENSE.md
[ma-encoder]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/video/Encoder.cpp
[ma-nvenc]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/video/NvidiaEncoder.cpp
