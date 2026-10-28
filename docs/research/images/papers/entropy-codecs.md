# Papers: Entropy codecs and modern codec architecture

The entropy-coding literature an image/video decoder in D has to answer to:
ANS and its table/interleaved forms, fast prefix-code decoding, adaptive
arithmetic coding with context models, and how JPEG XL, AV1, WebP lossless and
HEVC/HEIC put these pieces together.

| Field             | Value                                                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **Thread**        | `entropy-codecs`                                                                                                              |
| **Scope**         | ANS/tANS/rANS, Huffman/prefix decoding speed, context modelling, and what JPEG XL, AV1, WebP lossless and HEIC do differently |
| **Entries**       | 23                                                                                                                            |
| **Last reviewed** | October 28, 2026                                                                                                              |

> [!NOTE]
> Quote page numbers ("p. N") are PDF page indices, not printed folios. Quotes
> from the three blog posts cite the web page instead.

## Why this thread matters to sparkles

Every format `sparkles:image` and `sparkles:video` decode bottoms out in an
entropy decoder, and that loop is where three of the project's concerns meet.
**Codec architecture**: JPEG XL, AV1, HEVC and WebP lossless each made a
different choice (rANS vs. prefix codes, multi-symbol vs. binary arithmetic
coding, static vs. adaptive models, where context is derived), and a generic
`sparkles` abstraction for "token stream decoder with contexts" must express all
of them without per-format forks. **SIMD and GPU compute**: entropy decoding is
inherently serial per stream, so throughput comes from interleaving streams
(ANS lanes, HEVC wavefronts, AV1 tiles) or from side metadata (gap arrays,
Recoil split states) — format-level decisions that determine whether a
`shaders` compute kernel or a SIMD loop can help at all. **Hostile input**: the
bit reader, the table builder (complete prefix trees, histogram sums) and the
memory budget (LZ77 windows, ANS tables, work buffers) are the classic overflow
and resource-exhaustion surfaces, so `wired`-style checked parsing and
`event-horizon`-style budgeted, streamed I/O both have to reach down into this
layer.

## Annotated bibliography

### Duda 2013 — Asymmetric numeral systems

| Field        | Value                                                                                    |
| ------------ | ---------------------------------------------------------------------------------------- |
| Authors      | Jarek Duda                                                                               |
| Venue/Year   | arXiv preprint, 2013 (v2 January 2014)                                                   |
| DOI or arXiv | [arXiv:1311.2540][duda-ans]                                                              |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/duda2013-asymmetric-numeral-systems.pdf` |
| Open access  | Y                                                                                        |

**Claim.** ANS encodes information into a single natural-number state by adding
digits at the least significant position with asymmetric proportions, which
reaches arithmetic-coding compression while keeping Huffman-like decode cost.
Because the state is one integer, the whole coder for a fixed distribution can
be tabulated as a small automaton (tANS), and the paper also introduces the
range variant (rANS) and binary variants.

> This advantage is due to being simpler than AC: using single natural number
> as the state, instead of two to represent a range.
> — p. 1

**Relevance to sparkles.** The single-word state is what makes ANS fit a
`@nogc` struct with no heap: a decoder is `(state, table slice, bit reader)`.
JPEG XL (rANS) and zstd (tANS/FSE) both descend from this paper, so a shared
`sparkles` ANS core can serve the JPEG XL decoder and any zstd-compressed
container payload.

**Caveats.** Preprint, revised several times; the speed numbers cite a 2013
implementation. Patent activity around rANS variants (notably a Microsoft
filing) postdates the paper and was not reviewed here; check before shipping an
adaptive-rANS encoder. The cryptographic use mentioned in the abstract is not a
security property to rely on.

### Giesen 2014 — Interleaved entropy coders

| Field        | Value                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------ |
| Authors      | Fabian Giesen                                                                              |
| Venue/Year   | arXiv preprint, 2014                                                                       |
| DOI or arXiv | [arXiv:1402.3392][giesen-interleave]                                                       |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/giesen2014-interleaved-entropy-coders.pdf` |
| Open access  | Y                                                                                          |

**Claim.** Because an ANS decoder's state equals the encoder's state at the
same point, several ANS coders can share one bitstream with no extra metadata;
this enables superscalar, SIMD and GPU decoding. The paper also shows the
catch: unless renormalisation is bounded to one step per symbol, the
interleaving order bakes the SIMD width into the format.

> As a consequence, the output from multiple ABS/ANS coders can be interleaved
> into the same bitstream without any additional metadata.
> — p. 1

**Relevance to sparkles.** This is the design rule for any `sparkles`-owned
container or intermediate format: interleave N rANS streams with a
one-renormalisation-per-symbol constraint (the paper's 16-bit radix with 12–14
bit probabilities) so the same bytes decode on a scalar path, an AVX2/NEON path
and a `shaders` compute kernel. For foreign formats, it tells the decoder
author when lane-parallelism is available for free and when it is not.

**Caveats.** Preprint; measurements are 2014 x86 and are illustrative. The
generic "any entropy coder" interleaving costs encoder complexity.

### Townsend 2020 — A tutorial on the range variant of ANS

| Field        | Value                                                                           |
| ------------ | ------------------------------------------------------------------------------- |
| Authors      | James Townsend                                                                  |
| Venue/Year   | arXiv preprint, 2020 (v3 October 2020)                                          |
| DOI or arXiv | [arXiv:2001.09186][townsend]                                                    |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/townsend2020-rans-tutorial.pdf` |
| Open access  | Y                                                                               |

**Claim.** A short, self-contained derivation of rANS as `push`/`pop` on a
message `m = (s, t)`: a head integer `s` of `rs` bits kept at or above
`2^(rs-rt)`, and a stack `t` of `rt`-bit words. `pop` extracts a symbol and
then refills `s` from the stack until the invariant holds again; `push` is its
exact inverse, flushing words before the symbol is folded in. With quantised
probabilities of precision `r`, the paper proves the compressed length stays
within a small, stated overhead of the Shannon information content.

> The key difference between ANS and AC is in the order in which data are
> decoded : in ANS, compression is last-in-first-out (LIFO), or 'stack-like',
> while in AC it is first-in-first-out (FIFO), or 'queue-like'.
> — p. 1

**Relevance to sparkles.** The clearest statement of the invariants a D rANS
core should carry as contracts: the head-state range after every `pop`, the
`renorm_inverse` stopping condition before every `push`, and precision
parameters as template arguments (the paper uses `rs = 64`, `rt = 32`,
`r = 16`). The LIFO property is an API fact rather than a detail: an encoder
must process a block in reverse (or buffer it), so a `sparkles` encoder is
block-based with caller-owned scratch, while the decoder streams forward. The
round-trip identities `push(pop(m)) = m` and `pop(push(m, x)) = (m, x)` are a
ready-made property test.

**Caveats.** Tutorial scope: one state, no interleaving, no table (tANS) form,
no performance engineering. Its `pop` assumes a well-formed message — the paper
does not say what `renorm` does when the stack runs out — so a hostile-input
decoder must add the
underflow and final-state checks that RFC 8878 and JPEG XL specify.

### Collet 2013 — Finite State Entropy (blog)

| Field        | Value                         |
| ------------ | ----------------------------- |
| Authors      | Yann Collet                   |
| Venue/Year   | Blog post, December 2013      |
| DOI or arXiv | none — [web page][collet-fse] |
| Local PDF    | web source                    |
| Open access  | Y                             |

**Claim.** FSE is a table-driven tANS implementation that beats `zlib`'s Huffman
coder on both ratio and decode speed, with speed stable across probability
skews. In the comment thread Collet concedes the structural cost: unlike
Huffman, FSE cannot shrink its decode table by falling back to tree walking.

> Compared to zlib's Huffman entropy coder, it manages to outperform its
> compression ratio while besting it on speed, especially decoding speed.
> — web page

**Relevance to sparkles.** Sets the engineering baseline for a tANS decode
table: one 12-bit table (a few KiB) per distribution, so table construction —
not symbol decode — becomes the per-block fixed cost to budget when many small
blocks each carry their own distributions.

**Caveats.** Blog post, not peer reviewed; the numbers predate zstd and modern
Huffman decoders such as `huff0`'s 4-stream design. Superseded as a
specification by RFC 8878.

### Collet & Kucherawy 2021 — Zstandard (RFC 8878)

| Field        | Value                                                                             |
| ------------ | --------------------------------------------------------------------------------- |
| Authors      | Yann Collet, Murray S. Kucherawy (ed.)                                            |
| Venue/Year   | IETF RFC 8878 (Informational), February 2021                                      |
| DOI or arXiv | [10.17487/RFC8878][rfc8878]                                                       |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/collet2021-zstandard-rfc8878.pdf` |
| Open access  | Y                                                                                 |

**Claim.** Specifies zstd's FSE (tANS) and Huffman stages, both read backwards
from the end of each bitstream, with explicit "bitstream must be entirely
consumed" corruption rules. Its security section makes bounds checking and
memory limits a decoder obligation rather than an implementation nicety.

> A decoder has to demonstrate capabilities to detect and prevent any kind of
> data tampering in the compressed frame from triggering system faults, such as
> reading or writing beyond allowed memory ranges.
> — p. 36

**Relevance to sparkles.** The closest thing to a written hostile-input
contract for an ANS/Huffman decoder; `sparkles` decoders should adopt its two
rules directly: (1) exact-consumption checks at stream end, (2) a caller-set
memory budget that a well-formed but huge frame cannot exceed ("correctly
formed compressed frames with unreasonable memory requirements", p. 36).
Backward-read streams also need a bit reader that can start at the tail, which
a `sparkles` bit-reader abstraction should support from day one.

**Caveats.** Informational RFC; normative behaviour is whatever the reference
implementation does where the text is silent.

### Moffat 2019 — Huffman coding (survey)

| Field        | Value                                                                          |
| ------------ | ------------------------------------------------------------------------------ |
| Authors      | Alistair Moffat                                                                |
| Venue/Year   | ACM Computing Surveys 52(4), 2019                                              |
| DOI or arXiv | [10.1145/3342555][moffat]                                                      |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/moffat2019-huffman-coding.pdf` |
| Open access  | Y (author copy)                                                                |

**Claim.** A tutorial and survey that treats a prefix code as a set of
codeword lengths, uses canonical codes to avoid explicit trees, and shows that
a small truncated lookup table resolves most symbols in one step. It also
compares Huffman with arithmetic coding and ANS, and covers length-limited
codes (package-merge).

> That is, even a quite small truncated decoding table can allow canonical
> Huffman codes to be decoded using near-constant time per output symbol.
> — p. 18

**Relevance to sparkles.** Every format here (JPEG, DEFLATE/PNG, WebP lossless,
JPEG XL prefix mode) ships canonical code lengths, so one `sparkles` canonical
table builder — lengths in, two-level lookup table out, with the Kraft-sum
check that rejects over- and under-subscribed codes — can serve all of them.
The survey gives the vocabulary (`first_code`, `search_start`) and the
correctness argument for that builder.

**Caveats.** Algorithmic survey; no SIMD or GPU treatment, and no measurements
on current hardware.

### Giesen 2018 — Reading bits in far too many ways (blog series)

| Field        | Value                                                    |
| ------------ | -------------------------------------------------------- |
| Authors      | Fabian Giesen                                            |
| Venue/Year   | Blog series (parts 1–3), February–September 2018         |
| DOI or arXiv | none — [part 1][bits1], [part 2][bits2], [part 3][bits3] |
| Local PDF    | web source                                               |
| Open access  | Y                                                        |

**Claim.** Decomposes a bit reader into refill, peek and consume, compares
MSB-first and LSB-first buffers, and shows that amortising refills
("lookahead") is the main speed lever. Part 2 spells out the price: the reader
may run past the logical end of the stream, so the framing layer has to
guarantee padding, a footer, or a careful tail path.

> It certainly should never crash or read out of bounds; but beyond that, it
> implies certain thing about the way input buffering or the framing layer have
> to work.
> — part 2, web page

**Relevance to sparkles.** The direct blueprint for a D bit reader: a template
over bit order with `refill`/`peek`/`consume` primitives, a fast path that
assumes N bytes of slack, and a checked tail path. With `io_uring`-fed buffers
in `event-horizon`, `sparkles` can own the buffer and guarantee zero padding
after the payload — the option the post calls easiest ("putting something else
at the end").

**Caveats.** Blog posts, not peer reviewed; micro-architectural claims are
about 2018-era x86 cores.

### Tao 2021 — The fastest, safest PNG decoder in the world (Wuffs)

| Field        | Value                                                   |
| ------------ | ------------------------------------------------------- |
| Authors      | Nigel Tao                                               |
| Venue/Year   | Blog post, April 2021                                   |
| DOI or arXiv | none — [web page][wuffs-png]; [Wuffs repository][wuffs] |
| Local PDF    | web source                                              |
| Open access  | Y                                                       |

**Claim.** Wuffs' memory-safe PNG decoder is 1.22–2.75x faster than `libpng`
through SIMD checksums, 8-byte input refills and over-copying LZ77 output, and
by inflating the whole image at once into a work buffer instead of row by row.
The API states memory as a range: the caller grants between `M0` and `M1`
bytes and more buys speed.

> For Wuffs, reading 64 bits once per inner loop sped up its DEFLATE
> micro-benchmarks by up to 1.30x.
> — web page

**Relevance to sparkles.** Evidence that bounds safety and peak speed are
compatible when the safe language proves the fast path (Wuffs does it at
compile time; D can approximate it with `@safe` slices plus slack-guaranteed
buffers). The `M0`..`M1` work-buffer contract is a good model for a
`sparkles` decoder API that lets an `event-horizon` caller trade memory for
throughput explicitly.

**Caveats.** Vendor blog with a small benchmark set; Wuffs' proofs come from
its own language, which D does not have — the equivalent guarantees need
tests and fuzzing.

### Marpe, Schwarz & Wiegand 2003 — CABAC in H.264/AVC

| Field        | Value                                                                         |
| ------------ | ----------------------------------------------------------------------------- |
| Authors      | Detlev Marpe, Heiko Schwarz, Thomas Wiegand                                   |
| Venue/Year   | IEEE Trans. Circuits and Systems for Video Technology 13(7), 2003             |
| DOI or arXiv | [10.1109/TCSVT.2003.815173][cabac]                                            |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/marpe2003-cabac-h264-avc.pdf` |
| Open access  | Y (author copy)                                                               |

**Claim.** CABAC binarises each syntax element, selects a context model per
bin from neighbouring data, and drives a multiplication-free, table-based
binary arithmetic coder with 64-state probability estimation. A bypass mode
skips modelling for near-uniform bins; the paper reports 9–14 % bit-rate
savings over CAVLC.

> Alternatively, the bypass coding mode is chosen for selected bins in order to
> allow a speedup of the whole encoding (and decoding) process by means of a
> simplified coding
> — p. 3

**Relevance to sparkles.** HEVC (and so HEIC) inherits this engine, so a
`sparkles` HEIC path either links a decoder or implements CABAC. The
binarisation/context/bin-coder split is the right internal seam: context
selection is format-specific, the bin coder is shared.

**Caveats.** Author manuscript (page numbers differ from the journal).
H.264/HEVC are patent-encumbered through pools; check licensing before shipping
a decoder.

### Sullivan, Ohm, Han & Wiegand 2012 — Overview of HEVC

| Field        | Value                                                                           |
| ------------ | ------------------------------------------------------------------------------- |
| Authors      | Gary J. Sullivan, Jens-Rainer Ohm, Woo-Jin Han, Thomas Wiegand                  |
| Venue/Year   | IEEE Trans. Circuits and Systems for Video Technology 22(12), 2012              |
| DOI or arXiv | [10.1109/TCSVT.2012.2221191][hevc]                                              |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/sullivan2012-overview-hevc.pdf` |
| Open access  | Y (author copy)                                                                 |

**Claim.** HEVC keeps a single entropy coder (CABAC), uses fewer contexts than
H.264, and moves more bins to bypass mode for throughput. Parallelism is a
syntax-level feature: tiles are independently decodable rectangles, and
wavefront parallel processing lets CTU row `n+1` start two CTUs behind row `n`
by inheriting its context state.

> The context models of the entropy coder in each row are inferred from those
> in the preceding row with a two-CTU processing lag.
> — p. 4

**Relevance to sparkles.** HEIC is HEVC intra frames inside HEIF, so these
are the parallelism hooks a `sparkles` HEIC decoder can use: per-tile
work items on a thread pool, or wavefront scheduling with context snapshots.
Both need the decoder state to be a copyable value, which argues for a plain
struct context table rather than a pointer graph.

**Caveats.** Describes version 1 (2013); range extensions and SCC came later.
The HEIF container is out of this paper's scope: Hannuksela, Lainema and
Vadakital, "The High Efficiency Image File Format Standard", IEEE Signal
Processing Magazine 32(4), 2015, has no open PDF.

### Sze & Budagavi 2013 — CABAC throughput, HEVC vs. AVC

| Field        | Value                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------- |
| Authors      | Vivienne Sze, Madhukar Budagavi                                                                   |
| Venue/Year   | IEEE Workshop on Signal Processing Systems (SiPS), 2013                                           |
| DOI or arXiv | [10.1109/SiPS.2013.6674499][sze]                                                                  |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/sze2013-comparison-cabac-throughput-hevc-avc.pdf` |
| Open access  | Y (MIT author copy)                                                                               |

**Claim.** Quantifies the HEVC throughput redesign of CABAC: fewer
context-coded bins (motion-vector difference from 9 to 2, coefficient levels
from 14 to 1–2), fewer total bins, and grouping of bypass bins so several can
be processed per cycle. Reports 24–31 % average "BD-cycle" reduction versus AVC.

> Thus multiple bypass bins can be processed concurrently in the same cycle at
> lower power and area cost than context coded bins.
> — p. 2

**Relevance to sparkles.** In software the same insight means "batch the bypass
bins": a decoder can read a run of bypass bins as one wide bit extraction. It
also says where the irreducible serial cost lives (context-coded bins), which
is what any profiling of a `sparkles` HEVC/HEIC path will show.

**Caveats.** Hardware cycle model, not a software benchmark; the shorter
companion of the authors' TCSVT 2012 paper, which has no open PDF.

### Valin et al. 2016 — Daala

| Field        | Value                                                                                                                      |
| ------------ | -------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Jean-Marc Valin, Timothy B. Terriberry, Nathan E. Egge, Thomas Daede, Yushin Cho, Christopher Montgomery, Michael Bebenita |
| Venue/Year   | IEEE MMSP 2016                                                                                                             |
| DOI or arXiv | [10.1109/MMSP.2016.7813362][daala-doi], [arXiv:1608.01947][daala]                                                          |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/valin2016-daala-next-generation-video-codec.pdf`                           |
| Open access  | Y                                                                                                                          |

**Claim.** Daala replaces binary arithmetic coding with a multi-symbol range
coder of up to 16 values per symbol, using a multiply-free "piecewise integer
mapping" that accepts non-power-of-two totals. Coding several binary decisions
in one symbol reduces serial dependencies.

> This is equivalent to coding up to four binary values in parallel and reduces
> serial dependencies, allowing hardware implementations to use lower clock
> rates, and thus less power.
> — p. 2

**Relevance to sparkles.** The origin of AV1's entropy coder. For software the
lesson is the same as for hardware: fewer, larger symbols mean fewer
serially-dependent decoder steps per pixel, so a generic `sparkles`
"symbol decoder" interface should be M-ary, with binary as the `M = 2` case
rather than the primitive.

**Caveats.** Daala itself was never finalised; the AV1 coder differs in detail
(CDF adaptation, 15-bit precision).

### Han et al. 2021 — A technical overview of AV1

| Field        | Value                                                                                                                                                                                                 |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Jingning Han, Bohan Li, Debargha Mukherjee, Ching-Han Chiang, Adrian Grange, Cheng Chen, Hui Su, Sarah Parker, Sai Deng, Urvang Joshi, Yue Chen, Yunqing Wang, Paul Wilkins, Yaowu Xu, James Bankoski |
| Venue/Year   | Proceedings of the IEEE 109(9), 2021                                                                                                                                                                  |
| DOI or arXiv | [10.1109/JPROC.2021.3058584][av1-doi], [arXiv:2008.06091][av1]                                                                                                                                        |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/han2021-technical-overview-av1.pdf`                                                                                                                   |
| Open access  | Y (arXiv)                                                                                                                                                                                             |

**Claim.** AV1 codes all syntax elements with an M-ary arithmetic coder from
Daala (the paper gives `M` from 2 to 14), storing probabilities as 15-bit CDFs that adapt
after every symbol, with an adaptation rate that is fast early in a frame. Only
the top 9 bits of each CDF entry feed the coder so the multiply fits 16 bits;
coefficient coding is decomposed into a "level map" of symbol codings.

> To improve hardware throughput, AV1 adopts a dual model approach to make the
> involved multiplications fit in 16 bits.
> — p. 16

**Relevance to sparkles.** Defines the second big entropy family a `sparkles`
AVIF/AV1 path faces: adaptive CDFs, so per-symbol state writes, unlike
JPEG XL's static rANS tables. The 16-bit multiply also makes the decode step
SIMD-friendly across independent tiles. The same team designed AV1's in-loop
CDEF filter for vectorisation from the start (Midtskogen & Valin, ICASSP 2018,
[arXiv:1602.05975][cdef]), a useful precedent for which tools to target first.

**Caveats.** Overview of encoder-side design rationale as much as decoder
operation; the [AV1 specification][av1-spec] is normative.

### Rhatushnyak et al. 2019 — JPEG XL committee draft

| Field        | Value                                                                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Alexander Rhatushnyak, Jan Wassenberg, Jon Sneyers, Jyrki Alakuijala, Lode Vandevenne, Luca Versari, Robert Obryk, Zoltan Szabadka, and 10 others |
| Venue/Year   | arXiv (ISO/IEC JTC1/SC29/WG1 committee draft), 2019                                                                                               |
| DOI or arXiv | [arXiv:1908.03565][jxl-cd]                                                                                                                        |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/rhatushnyak2019-committee-draft-jpeg-xl.pdf`                                                      |
| Open access  | Y                                                                                                                                                 |

**Claim.** The public committee draft of what became ISO/IEC 18181-1,
including the ANS and prefix-code entropy decoding procedures. It defines
decoding normatively in terms of an "ill-formed codestream", with explicit
rejection conditions at nearly every read.

> When the decoder would consume a byte which is beyond the end of the
> codestream, the codestream is ill-formed.
> — p. 20

**Relevance to sparkles.** The "ill-formed" vocabulary maps one-to-one onto an
`Expected`-returning decoder: each normative rejection becomes an error enum
member, and a `wired` description of the headers can carry the same
conditions as checks.

**Caveats.** A draft that the final standard changed in places; the
editor's note says so. Use only for orientation; the ISO text is paywalled.

### Alakuijala et al. 2020 — Benchmarking JPEG XL image compression

| Field        | Value                                                                                                                                              |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Jyrki Alakuijala, Sami Boukortt, Touradj Ebrahimi, Evgenii Kliuchnikov, Jon Sneyers, Evgeniy Upenik, Lode Vandevenne, Luca Versari, Jan Wassenberg |
| Venue/Year   | Proc. SPIE 11353 (Optics, Photonics and Digital Technologies for Imaging Applications VI), 2020                                                    |
| DOI or arXiv | [10.1117/12.2556264][jxl-bench]                                                                                                                    |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/alakuijala2020-benchmarking-jpeg-xl.pdf`                                                           |
| Open access  | Y (submitted manuscript)                                                                                                                           |

**Claim.** Evaluates JPEG XL against JPEG, HEVC and others subjectively and
objectively, and reports multi-threaded encode/decode speeds on x86 and ARM.
It states that the entropy layer is either Huffman or alias-table rANS with
context modelling, and that the format was designed for multicore and SIMD
decoding.

> JPEG XL was designed to benefit from multicore and SIMD, and actually decodes
> faster than JPEG.
> — p. 1

**Relevance to sparkles.** Puts the speed claim on multicore and SIMD rather
than on the entropy coder itself. Read with the 2025 overview, which describes
independently decodable groups, this suggests a D implementation should
parallelise per group with an `event-horizon` task each and vectorise the
transforms, leaving the per-group entropy decoder scalar.

**Caveats.** Authored by the format's designers; benchmark corpus and
`libjxl` versions are from 2019–2020.

### Sneyers et al. 2025 — The JPEG XL image coding system

| Field        | Value                                                                                                                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Authors      | Jon Sneyers, Jyrki Alakuijala, Luca Versari, Zoltán Szabadka, Sami Boukortt, Amnon Cohen-Tidhar, Moritz Firsching, Evgenii Kliuchnikov, Tal Lev-Ami, Eric Portis, Thomas Richter, Osamu Watanabe |
| Venue/Year   | arXiv preprint, June 2025                                                                                                                                                                        |
| DOI or arXiv | [arXiv:2506.05987][jxl-2025]                                                                                                                                                                     |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/sneyers2025-jpeg-xl-image-coding-system.pdf`                                                                                                     |
| Open access  | Y (CC BY-SA 4.0)                                                                                                                                                                                 |

**Claim.** A companion to ISO/IEC 18181: JPEG XL unified six earlier entropy
coders into one "hybrid integer" scheme — prefix-coded or rANS-coded tokens
plus raw low bits, optional LZ77 with 2-D special distances — driven by MA
trees (signalled decision trees over local properties) and context clustering.
rANS uses alias mapping, a 32-bit state shared between contexts and 12-bit
static distributions, with a fixed final state that doubles as an integrity
check.

> This way, the final ANS state acts like a checksum that can be used to detect
> a corrupted (section of a) bitstream, e.g. due to transmission errors.
> — p. 52

**Relevance to sparkles.** The best single description of the entropy layer a
`sparkles` JPEG XL decoder must implement. Three concrete implications: the
hybrid-uint token is the generic "token + raw bits" abstraction worth
sharing across formats; the final-state check is a free hostile-input guard to
enforce; and LZ77's 2^20-symbol window "may require up to 4 megabytes of
memory" (p. 52), a budget the decoder API must expose rather than allocate
silently.

**Caveats.** Written by the format's designers; a preprint at the time of
review.

### Zern, Massimino & Alakuijala 2024 — WebP image format (RFC 9649)

| Field        | Value                                                                                   |
| ------------ | --------------------------------------------------------------------------------------- |
| Authors      | James Zern, Pascal Massimino, Jyrki Alakuijala                                          |
| Venue/Year   | IETF RFC 9649 (Informational), November 2024                                            |
| DOI or arXiv | [10.17487/RFC9649][rfc9649]                                                             |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/zern2024-webp-image-format-rfc9649.pdf` |
| Open access  | Y                                                                                       |

**Claim.** Includes the full WebP lossless bitstream: spatial transforms, then
LZ77 with 2-D distance codes, a hashed colour cache, and five canonical prefix
codes per "prefix code group", where a subsampled entropy image chooses the
group per block. Code lengths are themselves prefix-coded, and the text states
validity conditions for the trees.

> The described tree must be a complete binary tree.
> — p. 36

**Relevance to sparkles.** WebP lossless is spatially-varying Huffman: decoders
build many tables per image, so table construction speed and validation
(completeness, `max_symbol` bounds — "If max_symbol is larger than the size of
the alphabet for the symbol type, the bitstream is invalid", p. 38) matter as
much as per-symbol speed. The 2023 `libwebp` heap overflow (CVE-2023-4863)
was in Huffman table construction from crafted code lengths, which is why a
`sparkles` builder should validate lengths before writing any table entry.

**Caveats.** Informational RFC documenting `libwebp` behaviour; lossy WebP
(VP8's boolean arithmetic coder) is a different entropy design, which this RFC
delegates to RFC 6386.

### Horn et al. 2017 — Lepton

| Field        | Value                                                                                     |
| ------------ | ----------------------------------------------------------------------------------------- |
| Authors      | Daniel Reiter Horn, Ken Elkabany, Chris Lesniewski-Laas, Keith Winstein                   |
| Venue/Year   | USENIX NSDI 2017                                                                          |
| DOI or arXiv | [arXiv:1704.06192][lepton] (USENIX has no DOI)                                            |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/horn2017-lepton-compress-image-files.pdf` |
| Open access  | Y                                                                                         |

**Claim.** Lepton losslessly recompresses baseline JPEGs to 77 % of their size
by replacing the Huffman layer with a context-modelled, parallelised
arithmetic coder, decoding over nine times faster than PackJPG. It ran on
hundreds of billions of production decodes, inside `SECCOMP` with a
preallocated arena, and fuzzing still found parser bugs after release.

> Lepton allocates a zeroed 200-MiB region of memory upfront, before reading
> user data, and sets up pipes to each of its threads before initiating SECCOMP.
> — p. 6

**Relevance to sparkles.** Two lessons. Context modelling over decoded DCT
coefficients is where JPEG's slack lies (the same idea as JPEG XL's lossless
JPEG recompression). And the deployment pattern — fixed arena allocated before
touching input, then no syscalls — is a concrete model for a `sparkles`
sandboxed decode worker under `event-horizon`, with `@nogc` decoders drawing
from a preallocated allocator.

**Caveats.** Lepton is archived upstream, and its format has no specification
beyond the open-source implementation. Speed figures were measured on a Xeon
E5-2650 v2.

### Sitaridi et al. 2016 — Massively-parallel lossless data decompression

| Field        | Value                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------- |
| Authors      | Evangelia Sitaridi, Rene Mueller, Tim Kaldewey, Guy Lohman, Kenneth A. Ross                       |
| Venue/Year   | ICPP 2016, pp. 242–247                                                                            |
| DOI or arXiv | [10.1109/ICPP.2016.35][sitaridi-doi], [arXiv:1606.00519][sitaridi]                                |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/sitaridi2016-parallel-lossless-decompression.pdf` |
| Open access  | Y (arXiv)                                                                                         |

**Claim.** Gompresso, an Inflate-like GPU decompressor, gets intra-block
parallelism from two format-level choices rather than from speculation. Its
Huffman stage splits each block into sub-blocks whose compressed bit sizes are
stored in the header, so each GPU thread decodes one sub-block through
single-lookup tables built from the block's two canonical codes. Its LZ77 stage
either resolves nested back-references at run time inside a warp (MRR) or has
the compressor forbid same-warp nested back-references (Dependency
Elimination), trading a slightly lower ratio for a 2–3x faster decompression.
Against multi-core CPU libraries it reports 2x speed and 17 % energy saving.

> Each encoded sub-block is written to the output file, along with its
> compressed size in bits.
> — p. 3

**Relevance to sparkles.** The format-change side of GPU entropy decoding,
complementing Rivera et al.'s gap arrays and Recoil's split states: an offset
table costs a few bytes per sub-block and removes the serial bit-position
dependency entirely. For a `sparkles`-owned cache or intermediate format this
is the cheapest route to a `shaders` compute decode; Dependency Elimination
shows the same move applied to LZ77, where the encoder pays so the decoder can
stay parallel. Neither technique applies to standard DEFLATE/PNG streams, which
carry no such offsets.

**Caveats.** Gompresso is its own format, not DEFLATE-compatible; it is
evaluated on two datasets (a Wikipedia XML dump and a sparse matrix) on a 2016
Tesla K40, as bulk throughput rather than single-image latency. The sub-block
count is a run-time parameter that trades compression ratio for parallelism.

### Tian et al. 2021 — Revisiting Huffman coding on modern GPUs

| Field        | Value                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------ |
| Authors      | Jiannan Tian, Cody Rivera, Sheng Di, Jieyang Chen, Xin Liang, Dingwen Tao, Franck Cappello |
| Venue/Year   | IEEE IPDPS 2021, pp. 881–891 (arXiv v1 October 2020)                                       |
| DOI or arXiv | [10.1109/IPDPS49936.2021.00097][tian-doi], [arXiv:2010.10039][tian]                        |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/tian2021-revisiting-huffman-coding.pdf`    |
| Open access  | Y (arXiv)                                                                                  |

**Claim.** Treats Huffman _encoding_ on the GPU as four stages — histogram,
codebook construction, canonisation (which also produces the reverse codebook
for decoding), and bit emission — and parallelises each. Codebook construction
follows Ostadzadeh et al.'s algorithm, which produces code lengths directly
rather than a tree; emission uses a reduction that merges codewords to use
memory bandwidth. It reports up to 5.0x and 6.8x over the prior GPU encoder on
RTX 5000 and V100, and up to 3.3x over a multithreaded CPU encoder on two
28-core Xeons.

> This is confirmed by our experiment: constructing a Huffman codebook with
> 8,192 input symbols takes 144 ms on NVIDIA V100 GPU, which degrades the
> throughput of compressing 1 GB data to less than 10 GB/s.
> — p. 3

**Relevance to sparkles.** Confirms the stage split a `sparkles` encoder API
should expose: histogram and code-length construction are separate, checked
steps with their own scratch, and a canonical codebook is the single artefact
that both the encoder and the decoder table builder consume. The quoted
measurement shows that a naive tree build, not symbol emission, can dominate
once alphabets are large — the encoder-side mirror of the decoder's per-block
table-construction cost.

**Caveats.** Built for `cuSZ`'s scientific data, with alphabets up to tens of
thousands of symbols; image codecs use alphabets of a few hundred, where
construction cost is much smaller. CUDA-only (Cooperative Groups); a Vulkan
compute port has to re-establish the bandwidth figures.

### Rivera et al. 2022 — Optimizing Huffman decoding on GPUs

| Field        | Value                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------------ |
| Authors      | Cody Rivera, Sheng Di, Jiannan Tian, Xiaodong Yu, Dingwen Tao, Franck Cappello                   |
| Venue/Year   | IEEE IPDPS 2022                                                                                  |
| DOI or arXiv | [10.1109/IPDPS53621.2022.00075][rivera-doi], [arXiv:2201.09118][rivera]                          |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/rivera2022-optimizing-huffman-decoding-gpus.pdf` |
| Open access  | Y (arXiv)                                                                                        |

**Claim.** Compares and optimises the two GPU Huffman decoding strategies:
self-synchronisation (Weißenberger & Schmidt, ICPP 2018), which needs no
encoder cooperation but decodes data multiple times to find sync points, and
gap arrays (Yamamoto et al., ICPP 2020), which store per-subsequence bit
offsets (under 3 % overhead) but couple encoder and decoder.

> However, the extra work the encoder must perform in generating the gap array
> means that the encoder and the decoder must be coupled.
> — p. 4

**Relevance to sparkles.** For foreign formats (JPEG, PNG, WebP) only
self-synchronisation applies, and it is data-dependent and redundant; GPU
Huffman decoding of existing files is therefore a poor first target for
`shaders` compute. For formats `sparkles` writes itself, side metadata is
cheap and makes GPU decode practical.

**Caveats.** Evaluated on scientific (`cuSZ`) data with large alphabets on a
V100, not image bitstreams. The ICPP 2018 Weißenberger & Schmidt paper
([10.1145/3225058.3225076][weiss18]) has no open PDF.

### Lin et al. 2023 — Recoil: parallel rANS decoding

| Field        | Value                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------ |
| Authors      | Fangzheng Lin, Kasidis Arunruangsirilert, Heming Sun, Jiro Katto                           |
| Venue/Year   | ICPP 2023                                                                                  |
| DOI or arXiv | [10.1145/3605573.3605588][recoil-doi], [arXiv:2306.12141][recoil]                          |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/lin2023-recoil-parallel-rans-decoding.pdf` |
| Open access  | Y (arXiv)                                                                                  |

**Claim.** A single interleaved rANS bitstream can be decoded from any point
if the intermediate states there are known, so Recoil stores split-point
states and symbol indices as metadata instead of partitioning the input. The
metadata can be thinned to match a weaker decoder, and throughput matches
partitioned approaches (90+ GB/s reported on a Turing GPU).

> We discover that a single rANS-encoded bitstream can be decoded from any
> arbitrary position if the intermediate states are known.
> — p. 1

**Relevance to sparkles.** The ANS counterpart of gap arrays, with a better
property: the base bitstream is unchanged, so parallelism is an optional side
table. A `sparkles`-owned intermediate or cache format could carry Recoil-style
split metadata and decode on CPU lanes or a Vulkan compute queue from the same
bytes.

**Caveats.** Recent, single group; encoder throughput is traded away; GPU
results are CUDA-only.

### Lemire, Kurz & Rupp 2018 — Stream VByte

| Field        | Value                                                                        |
| ------------ | ---------------------------------------------------------------------------- |
| Authors      | Daniel Lemire, Nathan Kurz, Christoph Rupp                                   |
| Venue/Year   | Information Processing Letters 130, 2018                                     |
| DOI or arXiv | [10.1016/j.ipl.2017.09.011][svb-doi], [arXiv:1709.08990][svb]                |
| Local PDF    | `~/code/repos/papers/image-video/entropy-codecs/lemire2018-stream-vbyte.pdf` |
| Open access  | Y (arXiv)                                                                    |

**Claim.** Separating the length-control bytes from the payload bytes lets a
SIMD decoder load the control byte, look up a shuffle mask and decode four
integers per instruction group, reaching over 4 billion integers per second
— at times faster than `memcpy`.

> we present STREAM VBYTE, a novel byte-oriented compression technique that
> separates the control stream from the encoded data.
> — p. 1 (the paper sets the name in small capitals)

**Relevance to sparkles.** Not an image entropy coder, but the general rule
for SIMD-decodable metadata: put the "how long is the next item" information in
its own stream. Applies to `sparkles`-owned sidecar formats (tile indices,
offset tables) and to `wired` encodings of variable-length integer arrays.

**Caveats.** Byte-aligned, so it compresses worse than bit-level codes; x86
SSE-centric evaluation.

## Thread synthesis

**Consensus.**

- Per-symbol entropy decoding is serial; throughput comes from running many
  independent streams. Every modern design builds that in at the format level:
  interleaved ANS lanes (Giesen), tiles and wavefronts (HEVC), tiles (AV1),
  256x256 groups (JPEG XL).
- Table-driven decoding wins on CPUs: canonical Huffman with a small first-level
  table (Moffat), tANS/FSE tables (Collet), JPEG XL's alias-mapped rANS. The
  canonical codebook is also the natural hand-off between encoder and decoder
  (Tian et al. canonise before emitting; Sitaridi et al. ship canonical codes).
- Context modelling is where compression is gained, and it is format-specific;
  the bin/symbol coder underneath is generic (CABAC, Daala/AV1, JPEG XL MA
  trees, Lepton).
- Decoder robustness is a stated obligation, not an afterthought: RFC 8878's
  security section, JPEG XL's "ill-formed" rules, WebP's complete-tree rule,
  Lepton's sandbox and fuzzing history.

**Disagreements.**

- **Adaptive vs. static models.** AV1 adapts CDFs per symbol (more serial
  state, no table signalling); JPEG XL and zstd signal static distributions per
  context (cheap decode step, but per-block table construction).
- **Binary vs. M-ary arithmetic coding.** HEVC refined binary CABAC with bypass
  batching; Daala/AV1 moved to M-ary symbols to cut serial steps.
- **Prefix codes vs. ANS.** JPEG XL keeps both (prefix mode for speed or
  JPEG-compatibility, ANS for density); WebP lossless and DEFLATE stay
  Huffman-only; Collet argues tANS dominates `zlib` Huffman.
- **Where intra-stream parallelism comes from.** Format changes that store
  positions — sub-block bit sizes (Sitaridi et al.), gap arrays, Recoil's split
  states, interleaved ANS lanes — against speculation on unmodified streams
  (self-synchronisation in Weißenberger & Schmidt, as analysed by Rivera et
  al.). The first costs bytes and encoder cooperation; the second costs
  redundant, data-dependent work.
- **Where modelling cost lands.** Adaptive CDFs (AV1) put it in decoder state
  updated every symbol; static signalled distributions with context clustering
  (JPEG XL, zstd) put it in encoder search and per-block table signalling.

**Open problems.**

- GPU decoding of _existing_ Huffman-coded files remains awkward
  (self-synchronisation is redundant work); efficient GPU decode needs
  cooperative formats (gap arrays, Recoil, interleaved ANS).
- No paper here measures table-construction cost under adversarial "many tiny
  tables" inputs, which is the realistic attack on WebP/JPEG XL decoders.
- The padding/lookahead contract between bit reader and I/O layer (Giesen) is
  solved ad hoc per library.
- None of the GPU papers bounds the wasted work of speculative decoding on
  crafted input; it is an implementation limit, not a derived guarantee.

**What a D implementation should take from this.**

- One bit-reader template (`MSB`/`LSB`, forward/backward) with
  `refill`/`peek`/`consume`, a fast path that relies on buffer slack the
  `sparkles` I/O layer guarantees, and a checked tail path — never a per-format
  reader.
- One canonical prefix-code table builder shared by JPEG, PNG/DEFLATE, WebP
  lossless and JPEG XL prefix mode, which rejects incomplete or
  over-subscribed codes and out-of-range symbols before building the table.
- A static rANS/tANS core (`@safe pure nothrow @nogc`, state in a struct) used
  by JPEG XL and zstd payloads, enforcing the end-of-stream checks (JPEG XL's
  final-state value, zstd's full-consumption rule) and carrying Townsend's
  state-range invariants as contracts, with `push`/`pop` round-trips as the
  property test.
- Encoders as explicit stages — histogram, checked code construction and
  canonisation, then emission — with caller-owned scratch; ANS emission is
  block-based because rANS is LIFO (Townsend), and only the emission stage is
  inherently serial (Tian et al.).
- An M-ary adaptive range decoder for AV1 kept separate from the static coders:
  its per-symbol CDF update is a different performance and state model.
- Every decoder takes an explicit memory budget (LZ77 windows, table arenas,
  work buffers) and reports exceeding it as an `Expected` error, following
  RFC 8878 and Wuffs' `M0`..`M1` contract.
- Parallelise at the format's independence boundary (tile, group, CTU row)
  with `event-horizon` tasks; reserve SIMD for interleaved ANS lanes and bypass
  bins, and GPU entropy decoding for `sparkles`-owned formats with side
  metadata (sub-block offsets, gap arrays or Recoil states). Any speculative
  GPU decode of a foreign format gets a per-chunk work budget.
- Normative rejection rules ("ill-formed", "invalid", "corrupted") map
  one-to-one onto error enum members; fuzz each decoder from day one (Lepton,
  RFC 8878).

## Sources

- Duda, [Asymmetric numeral systems][duda-ans] (arXiv 2013).
- Giesen, [Interleaved entropy coders][giesen-interleave] (arXiv 2014).
- Townsend, [A tutorial on the range variant of ANS][townsend] (arXiv 2020).
- Collet, [Finite State Entropy][collet-fse] (blog 2013); Collet & Kucherawy,
  [RFC 8878][rfc8878] (2021).
- Moffat, [Huffman Coding][moffat] (ACM CSUR 2019).
- Giesen, Reading bits in far too many ways, [part 1][bits1], [part 2][bits2],
  [part 3][bits3] (blog 2018).
- Tao, [The Fastest, Safest PNG Decoder in the World][wuffs-png] (blog 2021);
  [Wuffs][wuffs].
- Marpe, Schwarz & Wiegand, [CABAC][cabac] (TCSVT 2003); Sullivan et al.,
  [Overview of HEVC][hevc] (TCSVT 2012); Sze & Budagavi,
  [CABAC throughput][sze] (SiPS 2013).
- Valin et al., [Daala][daala] (MMSP 2016); Han et al.,
  [A Technical Overview of AV1][av1-doi] (Proc. IEEE 2021);
  [AV1 bitstream specification][av1-spec]; Midtskogen & Valin, [CDEF][cdef].
- Rhatushnyak et al., [JPEG XL committee draft][jxl-cd] (2019); Alakuijala et
  al., [JPEG XL architecture and coding tools][jxl-spie] (SPIE 2019, no open
  PDF); Alakuijala et al., [Benchmarking JPEG XL][jxl-bench] (SPIE 2020);
  Sneyers et al., [The JPEG XL Image Coding System][jxl-2025] (arXiv 2025).
- Zern, Massimino & Alakuijala, [RFC 9649 WebP Image Format][rfc9649] (2024).
- Horn et al., [Lepton][lepton] (NSDI 2017).
- Weißenberger & Schmidt, [Massively Parallel Huffman Decoding on GPUs][weiss18]
  (ICPP 2018, no open PDF); Sitaridi et al.,
  [Massively-Parallel Lossless Data Decompression][sitaridi-doi] (ICPP 2016);
  Tian et al., [Revisiting Huffman Coding][tian-doi] (IPDPS 2021); Rivera et al., [GPU Huffman decoding][rivera]
  (IPDPS 2022); Lin et al., [Recoil][recoil] (ICPP 2023).
- Lemire, Kurz & Rupp, [Stream VByte][svb] (IPL 2018).
- Hannuksela, Lainema & Vadakital, [The High Efficiency Image File Format Standard][heif]
  (IEEE SPM 2015, no open PDF).

<!-- References -->

[duda-ans]: https://arxiv.org/abs/1311.2540
[giesen-interleave]: https://arxiv.org/abs/1402.3392
[collet-fse]: https://fastcompression.blogspot.com/2013/12/finite-state-entropy-new-breed-of.html
[rfc8878]: https://doi.org/10.17487/RFC8878
[moffat]: https://doi.org/10.1145/3342555
[bits1]: https://fgiesen.wordpress.com/2018/02/19/reading-bits-in-far-too-many-ways-part-1/
[bits2]: https://fgiesen.wordpress.com/2018/02/20/reading-bits-in-far-too-many-ways-part-2/
[bits3]: https://fgiesen.wordpress.com/2018/09/27/reading-bits-in-far-too-many-ways-part-3/
[wuffs-png]: https://nigeltao.github.io/blog/2021/fastest-safest-png-decoder.html
[wuffs]: https://github.com/google/wuffs/tree/4be865da258c4b5e6d3e716fd4f36be016496a46
[cabac]: https://doi.org/10.1109/TCSVT.2003.815173
[hevc]: https://doi.org/10.1109/TCSVT.2012.2221191
[sze]: https://doi.org/10.1109/SiPS.2013.6674499
[daala]: https://arxiv.org/abs/1608.01947
[daala-doi]: https://doi.org/10.1109/MMSP.2016.7813362
[av1]: https://arxiv.org/abs/2008.06091
[av1-doi]: https://doi.org/10.1109/JPROC.2021.3058584
[av1-spec]: https://aomediacodec.github.io/av1-spec/
[cdef]: https://arxiv.org/abs/1602.05975
[jxl-cd]: https://arxiv.org/abs/1908.03565
[jxl-spie]: https://doi.org/10.1117/12.2529237
[jxl-bench]: https://doi.org/10.1117/12.2556264
[jxl-2025]: https://arxiv.org/abs/2506.05987
[rfc9649]: https://doi.org/10.17487/RFC9649
[lepton]: https://arxiv.org/abs/1704.06192
[weiss18]: https://doi.org/10.1145/3225058.3225076
[townsend]: https://arxiv.org/abs/2001.09186
[sitaridi]: https://arxiv.org/abs/1606.00519
[sitaridi-doi]: https://doi.org/10.1109/ICPP.2016.35
[tian]: https://arxiv.org/abs/2010.10039
[tian-doi]: https://doi.org/10.1109/IPDPS49936.2021.00097
[rivera]: https://arxiv.org/abs/2201.09118
[rivera-doi]: https://doi.org/10.1109/IPDPS53621.2022.00075
[recoil]: https://arxiv.org/abs/2306.12141
[recoil-doi]: https://doi.org/10.1145/3605573.3605588
[svb]: https://arxiv.org/abs/1709.08990
[svb-doi]: https://doi.org/10.1016/j.ipl.2017.09.011
[heif]: https://doi.org/10.1109/MSP.2015.2419292
