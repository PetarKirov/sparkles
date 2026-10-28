# Papers: Hostile-input safety

Image decoders are the most attacked parsers on the client, and the literature
converges on one answer: recognise a deliberately small input language completely,
in code whose safety is checked mechanically, before any pixel work begins.

| Field              | Value                                                                                                                               |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| Thread             | `hostile-input-safety`                                                                                                              |
| Scope              | Language-theoretic security, parser generators and verified parsers, differential testing, fuzzing, image-codec CVE analyses, Wuffs |
| Entries            | 26 (21 peer-reviewed or archival papers, 1 technical report, 1 invited-talk slide deck, 3 primary web sources)                      |
| **Last reviewed:** | October 28, 2026                                                                                                                    |

> [!NOTE]
> Quote page numbers are **PDF page indices** of the local file (p. 1 is the first
> page of the PDF, whatever folio is printed on it); for the slide deck the index is
> the slide number. Quotes from web-only sources are from the page at the linked URL.

## Why this thread matters to sparkles

`sparkles:{image,video}` will parse PNG, JPEG, WebP, GIF, AVIF/HEIF containers and
video bitstreams that arrive from the network, the clipboard and the file system, then
hand pixels to SIMD kernels, Vulkan compute and `io_uring` upload paths. Every one of
those stages trusts the header decoder's arithmetic: a width × height × stride product,
a Huffman table size, a chunk length that names how many bytes to `memcpy` into a
staging buffer. The two in-the-wild image exploits in this thread (WebP `VP8L` Huffman
tables in 2023, Xpdf-derived JBIG2 in 2021) are exactly such arithmetic mistakes, in
heavily fuzzed C. The **hostile input** concern therefore shapes the **codec
architecture** (a separate recogniser stage, caller-owned buffers, no allocation in the
decoder core), the **generic image abstractions** (validated dimensions as a type, not
an `int`), the **storage-to-GPU I/O** path (sizes fixed before a buffer is mapped), and
the testing plan (`wired`-described formats that can generate fuzzers and differential
oracles). **SIMD** and **GPU compute** kernels inherit their bounds from the validated
header, so their safety argument starts here.

## Annotated bibliography

### Sassaman et al. 2011 — The Halting Problems of Network Stack Insecurity

| Field        | Value                                                                                                             |
| ------------ | ----------------------------------------------------------------------------------------------------------------- |
| Authors      | Len Sassaman, Meredith L. Patterson, Sergey Bratus, Anna Shubina                                                  |
| Venue/Year   | USENIX `;login:` 36(6), December 2011                                                                             |
| DOI or arXiv | none (magazine article; [author copy][sassaman2011])                                                              |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/sassaman2011-halting-problems-network-stack-insecurity.pdf` |
| Open access  | Y                                                                                                                 |

**Claim.** The founding LangSec essay: treat every input format as a formal language,
keep it as low on the Chomsky hierarchy as possible, and recognise it completely before
processing. A format whose validity cannot be decided simply cannot in practice be
secured, and two parsers of a language beyond deterministic context-free cannot even be
checked for equivalence.

**Verbatim quote** (p. 8):

> An input language should only be as computationally complex as absolutely needed, so
> that the computational power of the parser necessary for it can be minimized.

**Relevance to sparkles.** Image containers are mostly length-prefixed TLV chunks
(PNG, RIFF/WebP, ISOBMFF boxes), which are context-sensitive only through length
fields. A `wired` format description should express exactly that power — bounded
lengths, counts, fixed tags — and nothing more (no arbitrary seeks or back-references
in the description language), so recognisers stay single-pass and their acceptance set
is analysable.

**Caveats.** Position paper, no evaluation. Its "principles" are design guidance; the
undecidability arguments concern grammar classes, not the bounded, length-delimited
formats that dominate images.

### Sassaman et al. 2013 — Security Applications of Formal Language Theory

| Field        | Value                                                                                                                                                                                                                                               |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Len Sassaman, Meredith L. Patterson, Sergey Bratus, Michael E. Locasto                                                                                                                                                                              |
| Venue/Year   | IEEE Systems Journal 7(3), September 2013, pp. 489–500; preprint [Dartmouth TR2011-709][sassaman2013-tr] (November 2011, adds Anna Shubina)                                                                                                         |
| DOI or arXiv | [`10.1109/JSYST.2012.2222000`][sassaman2013-doi]                                                                                                                                                                                                    |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/sassaman2013-security-formal-language-theory.pdf` (journal print); TR at `~/code/repos/papers/image-video/hostile-input-safety/sassaman2013-security-applications-formal-language-theory.pdf` |
| Open access  | Y (TR); journal N                                                                                                                                                                                                                                   |

**Claim.** The long-form theory behind LangSec: insecure composition arises when
components must solve undecidable recognition or equivalence problems. It introduces
the **parse tree differential** attack, in which two implementations of "the same"
format accept different languages, and uses PKCS#1 signature forgery as a worked
context-sensitive example.

**Verbatim quote** (p. 1, journal print):

> We also introduce a formalization of an exploit development technique, the parse
> tree differential attack, made possible by our conception of the role of formal
> grammars in security.

**Relevance to sparkles.** A `sparkles:image` decoder and the platform decoder
(`libpng`, ImageIO, a browser) will disagree on some files. Where `sparkles` output
feeds a security decision (thumbnailers, content filters, hashes of "the image"), the
accepted language must be documented and differentially tested against a reference.
Inside `sparkles` the same rule means one recogniser per format: the sniffer, the
decoder, the colour-profile parser and the GPU upload path consume its validated model
instead of each re-reading the hostile header bytes.

**Caveats.** The constructive programme predates EverParse, Wuffs and coverage-guided
fuzzing, so it is directional rather than a tool evaluation; its strongest
prescriptions apply to formats one designs, while `sparkles` mostly implements formats
designed by others.

### Momot et al. 2016 — The Seven Turrets of Babel

| Field        | Value                                                                                                     |
| ------------ | --------------------------------------------------------------------------------------------------------- |
| Authors      | Falcon Darkstar Momot, Sergey Bratus, Sven M. Hallberg, Meredith L. Patterson                             |
| Venue/Year   | IEEE SecDev 2016                                                                                          |
| DOI or arXiv | [`10.1109/SecDev.2016.019`][momot2016-doi]                                                                |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/momot2016-seven-turrets-of-babel.pdf` (author copy) |
| Open access  | Y (author copy)                                                                                           |

**Claim.** Turns LangSec into an auditable taxonomy of input-handling weaknesses
(shotgun parsing, non-minimalist input handling, incomplete specification, overloaded
fields, permissive processing of invalid input, and others) with proposed CWE entries,
so that "this parser feels wrong" becomes a finding.

**Verbatim quote** (p. 3):

> Shotgun parsing is a programming antipattern whereby parsing and input-validating
> code is mixed with and spread across processing code—throwing a cloud of checks at
> the input, and hoping, without any systematic justification, that one or another
> would catch all the “bad” cases.

**Relevance to sparkles.** A review checklist for every codec: no `enforce` scattered
through the inverse-DCT or filter loops; length and dimension checks live in the
recogniser; "permissive" acceptance of malformed files (a common `libpng`/browser
behaviour) is an explicit, named mode rather than an accident.

**Caveats.** Taxonomy without measurement; categories overlap in practice.

### Bratus et al. 2017 — Curing the Vulnerable Parser

| Field        | Value                                                                                                                         |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Sergey Bratus, Lars Hermerschmidt, Sven M. Hallberg, Michael E. Locasto, Falcon D. Momot, Meredith L. Patterson, Anna Shubina |
| Venue/Year   | USENIX `;login:` 42(1), Spring 2017                                                                                           |
| DOI or arXiv | none (magazine article; [USENIX page][bratus2017])                                                                            |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/bratus2017-curing-the-vulnerable-parser.pdf`                            |
| Open access  | Y                                                                                                                             |

**Claim.** Three design patterns from building a hardened DNP3 parser with `Hammer`:
the **Recognizer** (business logic only ever sees typed, fully validated objects), the
**Most Restrictive Input Definition** (deliberately subset the format), and the
**Unparser** (generate output from the same specification).

**Verbatim quotes** (p. 5 and p. 1):

> Importantly, the Parser only invokes the handle() method of the Handler interface
> after creating InputData objects.

> in a word, data format doomed the code.

**Relevance to sparkles.** Maps directly onto D: the recogniser returns an
`Expected!(ValidatedHeader, DecodeError)` whose type can only be constructed by the
recogniser (private constructor, `package` visibility), so pixel kernels cannot be
called on unchecked dimensions. "Most restrictive" argues for a strict default profile
(for example, reject PNG chunks after `IEND`, cap `IHDR` dimensions) with opt-in
leniency.

**Caveats.** Practitioner article; DNP3 is far simpler than modern image codecs, whose
entropy-coded payloads cannot be fully "recognised" before decoding.

### Bangert and Zeldovich 2014 — Nail

| Field        | Value                                                                       |
| ------------ | --------------------------------------------------------------------------- |
| Authors      | Julian Bangert, Nickolai Zeldovich                                          |
| Venue/Year   | OSDI 2014                                                                   |
| DOI or arXiv | none ([USENIX page][nail-usenix])                                           |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/bangert2014-nail.pdf` |
| Open access  | Y                                                                           |

**Claim.** A parser _and generator_ tool whose grammar also defines the in-memory object
model, removing semantic actions. **Dependent fields** (lengths, offsets, checksums) and
**stream transforms** (decompression, offsets into the file) are first-class, and the
redundant fields are consumed by the parser so applications never see two
copies that could disagree. Demonstrated on DNS and ZIP in C.

**Verbatim quote** (p. 2):

> security vulnerabilities can occur when an application assumes two repetitions of
> the same data to be consistent, such as allocating a buffer based on the value of one
> size field and copying into that buffer based on the value of another

**Relevance to sparkles.** This is the precise shape of CVE-2023-4863 and FORCEDENTRY
(allocate from one computed size, write from another). `wired` format descriptions for
images should model dependent fields so that a length is checked once and then
disappears from the decoded struct; stream transforms are the natural home for
`zlib`/`IDAT` concatenation and ISOBMFF `iloc` extents.

**Caveats.** Prototype tool, C output, not maintained; no formal proof. Its stream
transforms are hand-written C and thus outside the safety argument.

### Ramananandro et al. 2019 — EverParse

| Field        | Value                                                                                                                                                                                                  |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Authors      | Tahina Ramananandro, Antoine Delignat-Lavaud, Cédric Fournet, Nikhil Swamy, Tej Chajed, Nadim Kobeissi, Jonathan Protzenko                                                                             |
| Venue/Year   | USENIX Security 2019                                                                                                                                                                                   |
| DOI or arXiv | none ([USENIX page][everparse-usenix])                                                                                                                                                                 |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/ramananandro2019-everparse.pdf` (author build; the USENIX proceedings build is `ramananandro2019-everparse-alt.pdf`, where the quote is on p. 2) |
| Open access  | Y                                                                                                                                                                                                      |

**Claim.** `LowParse` combinators verified in F\* plus the `QuackyDucky` front end
generate zero-copy C validators and accessors for TLV formats (all of TLS 1.0–1.3,
Bitcoin, PKCS#1 DER), proven memory-safe, functionally correct and non-malleable,
with performance at or above hand-written libraries.

**Verbatim quote** (p. 1):

> The resulting code is verified to be safe (no overflow, no use after free), correct
> (parsing is the inverse of serialization) and non-malleable (each message has a
> unique binary representation).

**Relevance to sparkles.** Validates the "validate in place, then access through
checked views" architecture for container layers. Non-malleability matters if
`sparkles` ever content-addresses images (cache keys, dedup): two byte strings for one
image make hashes unreliable. The zero-copy accessor style fits `io_uring`-read buffers
that should not be copied before upload.

**Caveats.** Verified TCB is F\*/Z3/KaRaMeL; the `QuackyDucky` front end is unverified
but kept outside the TCB, because F\* checks its output against the emitted
specification. Targets TLV messages, not entropy-coded payloads. Reusing it from D
would mean consuming generated C via ImportC, not reproducing the proofs.

### Swamy et al. 2022 — Hardening Attack Surfaces with Formally Proven Binary Format Parsers (EverParse3D)

| Field        | Value                                                                                                                                               |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Nikhil Swamy, Tahina Ramananandro, Aseem Rastogi, Irina Spiridonova, Haobin Ni, Dmitry Malloy, Juan Vazquez, Michael Tang, Omar Cardona, Arti Gupta |
| Venue/Year   | PLDI 2022                                                                                                                                           |
| DOI or arXiv | [`10.1145/3519939.3523708`][swamy2022-doi]                                                                                                          |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/swamy2022-everparse3d-hardening-attack-surfaces.pdf` (author copy)                            |
| Open access  | Y                                                                                                                                                   |

**Claim.** The `3d` data-description language (C-like structs with value constraints
and data dependencies) compiles to verified C validators deployed in the Windows kernel
(Hyper-V networking, ~100 message types). Beyond memory and arithmetic safety it proves
**double-fetch freedom**: each input byte is read at most once, which matters when the
buffer is shared with an adversary.

**Verbatim quote** (p. 1):

> a parser generator for binary message formats that yields performant C code backed
> by fully automated formal proofs of memory safety, arithmetic safety, functional
> correctness, and even double-fetch freedom to prevent certain kinds of
> time-of-check/time-of-use errors.

**Relevance to sparkles.** Double-fetch freedom is relevant whenever `sparkles` parses
directly out of memory another party can still write: `mmap`ed files, shared-memory
clipboard transfers, `io_uring` registered buffers. The design rule is "copy scalars out
once, validate the copy". The `3d` language (structs plus refinements) is also a close
model for what `wired` + UDAs can express in D.

**Caveats.** Industrial deployment report; formats are small network messages. The
local file is the authors' copy; the ACM version is canonical.

### Delaware et al. 2019 — Narcissus

| Field        | Value                                                                                   |
| ------------ | --------------------------------------------------------------------------------------- |
| Authors      | Benjamin Delaware, Sorawit Suriyakarn, Clément Pit-Claudel, Qianchuan Ye, Adam Chlipala |
| Venue/Year   | ICFP 2019 (PACMPL 3, ICFP, Article 82)                                                  |
| DOI or arXiv | [`10.1145/3341686`][delaware2019-doi]; [`arXiv:1803.04870`][delaware2019-arxiv]         |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/delaware2019-narcissus.pdf`       |
| Open access  | Y                                                                                       |

**Claim.** From one non-redundant format specification, Coq tactics derive both a
decoder and an encoder that are proven inverse; applied to the full packet stack of the
MirageOS unikernel with small overhead.

**Verbatim quote** (p. 1):

> The catch is that we use the Coq proof assistant to derive both kinds of artifacts
> using tactics, automatically, in a way that guarantees that they form inverses of each
> other.

**Relevance to sparkles.** The round-trip property (`decode(encode(x)) == x`, and
`encode(decode(b)) == b` on canonical inputs) is the cheapest oracle `sparkles` can test
without proofs: property tests on every `wired`-described header and container, run in
`@ctfe` where the description is CTFE-able.

**Caveats.** Proof-assistant workflow; specification of compressed payloads is out of
scope. The paper is sometimes cited as PLDI; it appeared at ICFP.

### Diatchki et al. 2024 — Daedalus: Safer Document Parsing

| Field        | Value                                                                                                                           |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Iavor S. Diatchki, Mike Dodds, Harrison Goldstein, Bill Harris, David A. Holland, Benoit Razet, Cole Schlesinger, Simon Winwood |
| Venue/Year   | PLDI 2024 (PACMPL 8, PLDI, Article 180)                                                                                         |
| DOI or arXiv | [`10.1145/3656410`][diatchki2024-doi]                                                                                           |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/diatchki2024-daedalus.pdf` (CC BY 4.0 ACM version)                        |
| Open access  | Y                                                                                                                               |

**Claim.** A parser-combinator DSL from DARPA SafeDocs with explicit **stream
manipulation** for non-contiguous formats (PDF cross-reference tables, NITF segments).
Twenty formats implemented; C++ and Haskell back ends; the PDF reference parser was the
only one in a red-team exercise found free of defects.

**Verbatim quote** (p. 1):

> We worked with the PDF Association to build a reference implementation, which was
> subject to a red-teaming exercise along with a number of other PDF parsers and was
> the only parser to be found free of defects.

**Relevance to sparkles.** Image containers are non-contiguous too: ISOBMFF `iloc`
extents (AVIF/HEIF), TIFF IFD offsets, JPEG APP segments referenced by EXIF offsets. A
`wired` description needs a first-class "sub-stream at offset/length" with a bounds and
overlap policy, rather than letting decoders seek ad hoc. Also an argument for a
documented strict PDF-style "reference implementation" mode.

**Caveats.** Safety comes from the generated code and the target language, not from a
proof; evaluation is a single red-team exercise.

### Tao et al. 2026 — Wuffs: Wrangling Untrusted File Formats Safely (repository documentation)

| Field        | Value                                                                                                                                                                                              |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Nigel Tao and Wuffs contributors (Google)                                                                                                                                                          |
| Venue/Year   | Repository docs, `README.md` and `doc/note/memory-safety.md` at commit `4be865da258c` (October 21, 2026); background in Tao's 2021 article [The Fastest, Safest PNG Decoder in the World][tao2021] |
| DOI or arXiv | none ([README][wuffs-readme], [memory-safety note][wuffs-memsafety])                                                                                                                               |
| Local PDF    | web source                                                                                                                                                                                         |
| Open access  | Y                                                                                                                                                                                                  |

**Claim.** A memory-safe, hermetic language transpiled to C for decoders (PNG, GIF,
JPEG, WebP, BMP, deflate, LZW…). Bounds, integer overflow and null checks are
discharged **at compile time** by programmer-supplied facts, so inner loops carry no
runtime checks. Wuffs code cannot allocate or do I/O: callers own every buffer, and image
decoding is split into "decode config" → caller allocates → "decode frame".

**Verbatim quotes** (`README.md` and `doc/note/memory-safety.md` at the pinned commit):

> A key difference between Wuffs and other memory-safe languages is that all such
> checks are done at compile time, not at run time.

> It's always caller-owned and callee-borrowed.

**Relevance to sparkles.** The strongest single design precedent for
`sparkles:image`: a `@safe pure nothrow @nogc` decoder core that takes caller-provided
input and pixel buffers and never allocates; a two-phase API whose first phase returns
the dimensions so the caller can refuse "too large" before allocating (and can allocate
directly into a Vulkan staging buffer); and Sans-I/O coroutines that fit `event-horizon`
completion loops without colouring the decoder. D cannot discharge bounds checks
statically the way Wuffs does, so hot loops need a measured `@trusted` slice idiom or
iteration patterns that let LDC elide checks.

**Caveats.** Not a paper; claims of speed are the project's own benchmarks. The proof
discipline costs authoring time, which the README states openly.

### Miller, Fredriksen and So 1990 — An Empirical Study of the Reliability of UNIX Utilities

| Field        | Value                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------------- |
| Authors      | Barton P. Miller, Lars Fredriksen, Bryan So                                                                      |
| Venue/Year   | Communications of the ACM 33(12), December 1990, pp. 32–44 (local file is the authors' 1989 report)              |
| DOI or arXiv | [`10.1145/96267.96279`][miller1990-doi]                                                                          |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/miller1990-empirical-study-reliability-unix-utilities.pdf` |
| Open access  | Y ([author copy][miller1990])                                                                                    |

**Claim.** The origin of fuzzing: a random-character generator fed to almost 90
utilities on seven UNIX versions crashed or hung 24–33% of them per system (the summary
rounds this to 25–33% crashed), including commercially tested versions. Among the causes, grouped by category, pointer and array
accesses that never check the array's range were one of the most common, beside
unchecked return codes, input functions and signed characters; the paper ends with
coding guidelines.

**Verbatim quotes** (p. 1 and p. 17):

> In our recent experiments, we have been able to crash 25-33% of the utility programs
> on any version of UNIX that was tested.

> All array references should be checked for valid bounds. This is an argument for
> using range checking full-time.

**Relevance to sparkles.** "Range checking full-time" is D's default for `@safe` code
and is kept in the repository's shipping `checked` build type; the guideline argues
against any codec configuration that turns bounds checks off. It also sets the floor
for testing: a decoder that has not survived random and truncated input has not been
tested at all, so a bytes-in harness exists from the first commit of each codec.

**Caveats.** Black-box random streams with crash/hang as the only oracle; no coverage
feedback, structure awareness or sanitizers. Random bytes rarely pass the magic numbers
and CRCs of an image container, so its crash rates do not transfer to decoders.

### Yang et al. 2011 — Finding and Understanding Bugs in C Compilers (Csmith)

| Field        | Value                                                                                                                       |
| ------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Xuejun Yang, Yang Chen, Eric Eide, John Regehr                                                                              |
| Venue/Year   | PLDI 2011, pp. 283–294                                                                                                      |
| DOI or arXiv | [`10.1145/1993498.1993532`][yang2011-doi]                                                                                   |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/yang2011-finding-understanding-bugs-c-compilers.pdf` (author version) |
| Open access  | Y ([author copy][yang2011])                                                                                                 |

**Claim.** `Csmith` generates random C programs that avoid all 191 undefined and 52
unspecified behaviours of C99, so that every program has one meaning; compiling each
with several compilers and comparing outputs found more than 325 previously unknown
bugs in three years, and every compiler tested both crashed and silently miscompiled.
The oracle is agreement among independent implementations, which needs no
specification of the right answer and catches wrong output that crash-only testing
cannot.

**Verbatim quote** (p. 2):

> It exploits the idea that if one has multiple, deterministic implementations of the
> same specification, all implementations must produce the same result from the same
> valid input. When two implementations produce different outputs, one of them must be
> faulty.

**Relevance to sparkles.** The image analogue: decode one corpus with `sparkles`, the
scalar D reference path and pinned reference decoders, and require agreement on
accept/reject, dimensions and pixels. `Csmith`'s condition on _valid_, single-meaning
input carries over directly: only lossless formats and integer-exact paths have one
correct output, so lossy decoders need a tolerance oracle and generators should keep
lossy-path inputs within what the specification fixes.

**Caveats.** Compiler-specific; it notes that agreement can only flag a bug when the
implementations disagree, so a fault shared by all of them goes undetected. For
images, permissive acceptance in a C reference decoder must not become ground truth.

### Petsios et al. 2017 — NEZHA: Efficient Domain-Independent Differential Testing

| Field        | Value                                                                              |
| ------------ | ---------------------------------------------------------------------------------- |
| Authors      | Theofilos Petsios, Adrian Tang, Salvatore Stolfo, Angelos D. Keromytis, Suman Jana |
| Venue/Year   | IEEE S&P 2017                                                                      |
| DOI or arXiv | [`10.1109/SP.2017.27`][petsios2017-doi]                                            |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/petsios2017-nezha.pdf`       |
| Open access  | Y                                                                                  |

**Claim.** Differential testing guided by **δ-diversity** (asymmetries in the
behaviour of several implementations on one input) finds semantic discrepancies far
faster than running a coverage fuzzer on each target separately; 778 discrepancies
across ELF/XZ parsers, PDF viewers and TLS libraries.

**Verbatim quote** (p. 1):

> Differential testing uses similar programs as cross-referencing oracles to find
> semantic bugs that do not exhibit explicit erroneous behaviors like crashes or
> assertion failures.

**Relevance to sparkles.** A memory-safe D decoder will rarely crash; its remaining
bugs are wrong pixels and accept/reject disagreements. The test plan should fuzz
`sparkles` against `libpng`/`libjpeg-turbo`/`libwebp`/Wuffs and compare (accept?,
dimensions, pixel hash), with the oracle fed by the dev shell's pinned reference libraries
(the `font-oracle` HarfBuzz pattern).

**Caveats.** Requires several implementations of one format; legitimate disagreement
(colour management, lenient recovery) must be whitelisted or the signal drowns.

### Holler, Herzig and Zeller 2012 — Fuzzing with Code Fragments (LangFuzz)

| Field        | Value                                                                                        |
| ------------ | -------------------------------------------------------------------------------------------- |
| Authors      | Christian Holler, Kim Herzig, Andreas Zeller                                                 |
| Venue/Year   | USENIX Security 2012                                                                         |
| DOI or arXiv | none ([USENIX page][holler2012])                                                             |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/holler2012-fuzzing-code-fragments.pdf` |
| Open access  | Y                                                                                            |

**Claim.** `LangFuzz` generates programs from a context-free grammar and fills them
with code fragments learned from a test suite, preferring fragments of programs that
failed before. On Mozilla's JavaScript engine it found 105 new severe vulnerabilities in
three months, and 18 crash defects in PHP; its defects overlap with those of the
JavaScript-specific `jsfunfuzz` by only 15%, so the two complement each other.

**Verbatim quotes** (p. 1 and p. 8):

> In order to be effective, the fuzzed input must be common enough to pass elementary
> consistency checks

> LangFuzz and jsfunfuzz detect different defects (overlap of 15%) and thus should be
> used complementary to each other.

**Relevance to sparkles.** Image containers put magic bytes, CRCs and length fields in
front of the interesting code, so most byte-level mutants die in the reject path.
Recombining chunks and boxes taken from a corpus, and preferentially from historical
crashers (old `libpng` and `libwebp` CVE files), is the binary analogue of fragment
recombination; generating them from the same `wired` description as the parser keeps
generator and recogniser from drifting apart. The 15% overlap argues for running more
than one fuzzer style.

**Caveats.** Textual grammars only; binary formats with computed fields (lengths,
CRCs, entropy-coded payloads) need repair steps the paper does not address. Its
baselines predate coverage-guided fuzzing.

### Serebryany et al. 2012 — AddressSanitizer

| Field        | Value                                                                                      |
| ------------ | ------------------------------------------------------------------------------------------ |
| Authors      | Konstantin Serebryany, Derek Bruening, Alexander Potapenko, Dmitry Vyukov                  |
| Venue/Year   | USENIX ATC 2012                                                                            |
| DOI or arXiv | none ([USENIX page][asan-usenix])                                                          |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/serebryany2012-addresssanitizer.pdf` |
| Open access  | Y                                                                                          |

**Claim.** Shadow-memory instrumentation plus a redzone allocator detects heap, stack
and global out-of-bounds accesses and use-after-free at about 73% slowdown, cheap
enough to run under fuzzers; the enabling oracle for `libFuzzer`/OSS-Fuzz.

**Verbatim quote** (p. 1):

> Its average slowdown is just 73% yet it accurately detects bugs at the point of
> occurrence.

**Relevance to sparkles.** `ci --test-sanitize` already runs ASan under LDC. Fuzz
harnesses for `sparkles:image` must run ASan builds, especially across `@trusted`
SIMD kernels and ImportC'd reference codecs, where D's bounds checks do not apply.
Pool/arena allocators in `base` hide overflows from ASan unless they poison redzones.

**Caveats.** Detects only bugs an input reaches; misses intra-object overflows and
overflows that land in another valid allocation.

### Böhme, Pham and Roychoudhury 2016 — Coverage-based Greybox Fuzzing as Markov Chain (AFLFast)

| Field        | Value                                                                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Marcel Böhme, Van-Thuan Pham, Abhik Roychoudhury                                                                                                        |
| Venue/Year   | ACM CCS 2016, pp. 1032–1043; extended in IEEE Transactions on Software Engineering 45(5), 2019, pp. 489–506 (local file is the accepted TSE manuscript) |
| DOI or arXiv | [`10.1145/2976749.2978428`][bohme2016-doi] (CCS); [`10.1109/TSE.2017.2785841`][bohme2016-tse] (TSE)                                                     |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/boehme2016-coverage-based-greybox-fuzzing-markov-chain.pdf`                                       |
| Open access  | Y (accepted manuscript)                                                                                                                                 |

**Claim.** Modelling coverage-guided fuzzing as a Markov chain shows that most
generated inputs exercise the same few high-frequency paths. Power schedules that give
seeds on low-frequency paths more energy (implemented as `AFLFast`, an extension of
`AFL`) explore more paths with the same number of tests; on GNU binutils, in 24 hours,
`AFLFast` found three CVEs `AFL` did not and six others 7× faster.

**Verbatim quotes** (p. 1):

> We observe that most tests exercise the same few “high-frequency” paths

> In 24 hours, AFLFast exposes 3 previously unreported CVEs that are not exposed by AFL

**Relevance to sparkles.** Decoder paths are dominated by the common case (8-bit RGB,
baseline JPEG, non-interlaced PNG); the arithmetic that differs (palette, 16-bit,
CMYK, progressive, Adam7) sits on rare paths. Seed corpora and harness dictionaries
should be curated for those rare header combinations, and corpus health measured by
which paths are reached, not by corpus size.

**Caveats.** Evaluated on binutils with unique-crash and CVE counts, the kind of
evaluation Klees et al. later showed to be fragile; the Markov model only approximates
the mutator.

### Serebryany 2017 — OSS-Fuzz: Google's Continuous Fuzzing Service for Open Source Software

| Field        | Value                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------- |
| Authors      | Kostya Serebryany                                                                           |
| Venue/Year   | Invited talk, USENIX Security 2017 (slides; no proceedings paper)                           |
| DOI or arXiv | none ([USENIX talk page][ossfuzz2017])                                                      |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/serebryany2017-oss-fuzz.pdf` (slides) |
| Open access  | Y                                                                                           |

**Claim.** Fuzzing failed in practice for lack of infrastructure, not technique: code
owners did not fuzz continuously. An experimental 2015 service fuzzing OpenSSL,
FreeType, HarfBuzz and others found bugs in every project; OSS-Fuzz, launched on
December 1, 2016, runs `libFuzzer` and `AFL` with ASan, MSan and UBSan and reported
2000+ bugs in 60+ projects. The talk defines a fuzz target's contract and proposes
"fuzz-driven development": every API a fuzz target, tests as the seed corpus, CI
including continuous fuzzing.

**Verbatim quotes** (slide 13 and slide 26):

> Consumes any data: {abort,exit,crash,assert,timeout,OOM} == bug

> Equally applicable to “safer” languages, see e.g. rust-fuzz, go-fuzz

**Relevance to sparkles.** The fuzz-target contract is the shape of a `sparkles`
decoder entry point: deterministic, single-process, no global state, narrow. Its bug
definition counts timeouts and OOMs as bugs, which only works if the decoder enforces
resource limits itself (see Ding and Le Goues). For D, `assert` and `RangeError` are
findings, not acceptable outcomes; every fixed crash becomes a seed and a unit test.

**Caveats.** Slides, not a paper; the bug counts are the operator's and date from 2017.
Continuous fuzzing finds only what its harnesses reach (see Hawkes).

### Klees et al. 2018 — Evaluating Fuzz Testing

| Field        | Value                                                                                        |
| ------------ | -------------------------------------------------------------------------------------------- |
| Authors      | George Klees, Andrew Ruef, Benji Cooper, Shiyi Wei, Michael Hicks                            |
| Venue/Year   | ACM CCS 2018                                                                                 |
| DOI or arXiv | [`10.1145/3243734.3243804`][klees2018-doi]; [`arXiv:1808.09700`][klees2018-arxiv]            |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/klees2018-evaluating-fuzz-testing.pdf` |
| Open access  | Y                                                                                            |

**Claim.** All 32 surveyed fuzzing papers had evaluation flaws; the authors' own
experiments show seed choice, run length and crash deduplication can flip conclusions.
Guidelines: repeated trials with statistical tests, varied seeds, 24-hour runs, and
ground-truth bugs rather than "unique crashes".

**Verbatim quote** (p. 2):

> researchers should perform multiple trials and use statistical tests (Section 4);
> they should evaluate different seeds (Section 5), and should consider longer (≥ 24
> hour vs. 5 hour) timeouts (Section 6)

**Relevance to sparkles.** Any claim that "the D decoder survives fuzzing" or that a
structure-aware harness beats a byte-level one needs the same discipline: fixed seed
corpora checked in, multiple runs, coverage plus known-bug reproduction (old `libpng`/
`libwebp` CVE inputs as regression seeds).

**Caveats.** Methodological; its benchmark targets (binutils, `gif2png`) are dated.

### Ding and Le Goues 2021 — An Empirical Study of OSS-Fuzz Bugs

| Field        | Value                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------- |
| Authors      | Zhen Yu Ding, Claire Le Goues                                                                     |
| Venue/Year   | MSR 2021                                                                                          |
| DOI or arXiv | [`10.1109/MSR52588.2021.00026`][ding2021-doi]; [`arXiv:2103.11518`][ding2021-arxiv]               |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/ding2021-empirical-study-oss-fuzz-bugs.pdf` |
| Open access  | Y                                                                                                 |

**Claim.** 23,907 OSS-Fuzz bugs across 316 projects: continuous fuzzing finds bugs
quickly and most are fixed quickly, but timeouts (4,054) and OOMs (2,112) are among the
commonest fault types and disproportionately flaky (13% of all bugs are flaky), and bug
discovery shows punctuated equilibria: spikes interspersed among slow periods.

**Verbatim quote** (p. 1):

> However, flaky bugs, timeouts, and out of memory errors are problematic, people
> rarely file CVEs for security vulnerabilities, and fuzzing campaigns often exhibit
> punctuated equilibria, where developers might be surprised by large spikes in bugs
> found.

**Relevance to sparkles.** For image decoders, timeouts and OOMs _are_ the
vulnerabilities once memory safety holds (decompression bombs, 65535 × 65535 headers).
Resource limits (max pixels, max allocation, max work per byte) belong in the decoder
API and harness, so the fuzzer reports them deterministically rather than as flakes.

**Caveats.** Descriptive statistics over OSS-Fuzz's tracker; no per-format breakdown.

### Hazimeh, Herrera and Payer 2020 — Magma: A Ground-Truth Fuzzing Benchmark

| Field        | Value                                                                        |
| ------------ | ---------------------------------------------------------------------------- |
| Authors      | Ahmad Hazimeh, Adrian Herrera, Mathias Payer                                 |
| Venue/Year   | Proc. ACM Meas. Anal. Comput. Syst. 4(3) (SIGMETRICS 2021), December 2020    |
| DOI or arXiv | [`10.1145/3428334`][magma-doi]; [`arXiv:2009.01120`][magma-arxiv]            |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/hazimeh2020-magma.pdf` |
| Open access  | Y                                                                            |

**Claim.** Forward-ports real historical bugs into current versions of seven targets
(including `libpng` and `libtiff`) with canaries recording whether each bug was reached,
triggered and detected; evaluates seven fuzzers over 200,000 CPU-hours.

**Verbatim quote** (p. 1):

> For example, crash count—perhaps the most commonly-used performance metric—is
> inaccurate due to imperfections in deduplication techniques.

**Relevance to sparkles.** The canary idea transfers: when `sparkles` ports a decoder,
re-introduce historical CVE conditions (oversized Huffman tables, IDAT length
mismatches) behind a debug flag and confirm the harness reaches them. It also gives
ready-made `libpng`/`libtiff` bug inputs for differential tests.

**Caveats.** Benchmark of C targets; forward-ported bugs may not reflect natural bug
distributions.

### Dutra, Gopinath and Zeller 2023 — FormatFuzzer: Effective Fuzzing of Binary File Formats

| Field        | Value                                                                                             |
| ------------ | ------------------------------------------------------------------------------------------------- |
| Authors      | Rafael Dutra, Rahul Gopinath, Andreas Zeller                                                      |
| Venue/Year   | ACM Transactions on Software Engineering and Methodology 33(2), December 2023 (preprint 2021)     |
| DOI or arXiv | [`10.1145/3628157`][formatfuzzer-doi]; [`arXiv:2109.11277`][formatfuzzer-arxiv]                   |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/dutra2021-formatfuzzer.pdf` (arXiv version) |
| Open access  | Y                                                                                                 |

**Claim.** Compiles 010 Editor binary templates (PNG, JPEG, GIF, MP4, ZIP…) into a C++
parser, mutator and generator; driving `AFL` through "decision seeds" makes mutation
structure-aware, producing valid files at high rate and new bugs in `ffmpeg`.

**Verbatim quote** (p. 1):

> Existing fuzzers, however, are mostly format-agnostic, which makes them versatile,
> but also ineffective when a specific format is required.

**Relevance to sparkles.** If `wired` describes a format, the same description can
emit a generator and a structure-aware mutator for free — the D analogue of a binary
template. This targets exactly the WebP failure mode, where byte-flip mutation cannot
reach deep states behind checksums and entropy-coded tables.

**Caveats.** Templates are hand-written and can drift from the real format; the local
file is the arXiv preprint, the TOSEM article is canonical.

### Manès et al. 2019 — The Art, Science, and Engineering of Fuzzing: A Survey

| Field        | Value                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------------- |
| Authors      | Valentin J. M. Manès, HyungSeok Han, Choongwoo Han, Sang Kil Cha, Manuel Egele, Edward J. Schwartz, Maverick Woo |
| Venue/Year   | arXiv v4, April 2019; IEEE Transactions on Software Engineering 47(11), 2021, pp. 2312–2331                      |
| DOI or arXiv | [`10.1109/TSE.2019.2946563`][manes2019-doi]; [`arXiv:1812.00140`][manes2019-arxiv]                               |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/manes2019-art-science-engineering-fuzzing.pdf` (arXiv v4)  |
| Open access  | Y                                                                                                                |

**Claim.** A unified model fuzzer (preprocess, schedule, input generation, input
evaluation, configuration update) and a taxonomy of the literature by the decision
each stage makes. It separates generating inputs from judging executions: the **bug
oracle** decides whether an execution violated a security policy, and a crash is only
the cheapest such policy, which is why sanitizers matter. It also catalogues the
techniques for getting past input checksums.

**Verbatim quotes** (p. 2 and p. 12):

> A bug oracle is a program, perhaps as part of a fuzzer, that determines whether a
> given execution of the PUT violates a specific security policy.

> For example, when a PUT computes a checksum of an input before parsing it, many test
> cases will be rejected by the PUT.

**Relevance to sparkles.** ("PUT" is the program under test.) For a memory-safe
decoder the bug oracle is where the design work lies: sanitizers for `@trusted` and
ImportC code, differential pixel comparison, accept/reject agreement, and work and
memory budgets. Checksums are a format feature `sparkles` controls in its own
harnesses: a fuzz-only switch that skips PNG CRC and Adler-32 verification, or a
`wired` generator that recomputes them, is cheaper than the taint and symbolic
techniques the survey describes.

**Caveats.** A snapshot of the literature to 2019; as a survey it inherits the
evaluation weaknesses Klees et al. document in the papers it covers.

### Böhme, Cadar and Roychoudhury 2021 — Fuzzing: Challenges and Reflections

| Field        | Value                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------- |
| Authors      | Marcel Böhme, Cristian Cadar, Abhik Roychoudhury                                                        |
| Venue/Year   | IEEE Software 38(3), 2021                                                                               |
| DOI or arXiv | [`10.1109/MS.2020.3016773`][bohme2021-doi]                                                              |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/bohme2021-fuzzing-challenges-and-reflections.pdf` |
| Open access  | Y (CC BY 4.0)                                                                                           |

**Claim.** A Shonan-meeting synthesis of open problems: reaching deep bugs behind
structured inputs, measuring residual risk when a campaign finds nothing, fuzzing
evolving code, and combining greybox fuzzing with symbolic execution and static
analysis.

**Verbatim quote** (p. 3):

> Structure-aware and grammar-based fuzzing as well as the integration of static
> analysis and symbolic execution with greybox fuzzing are promising directions

**Relevance to sparkles.** Confirms the plan: structure-aware harnesses driven by
format descriptions, plus regression seeds, plus differential oracles. Also a caution
that "no crashes after N hours" says little about residual risk.

**Caveats.** Opinion/survey; no new data.

### Rebert and Kern 2024 — Secure by Design: Google's Perspective on Memory Safety

| Field        | Value                                                                                                       |
| ------------ | ----------------------------------------------------------------------------------------------------------- |
| Authors      | Alex Rebert, Christoph Kern                                                                                 |
| Venue/Year   | Google Security Engineering Technical Report, March 4, 2024                                                 |
| DOI or arXiv | none ([Google Research page][rebert2024-page])                                                              |
| Local PDF    | `~/code/repos/papers/image-video/hostile-input-safety/rebert2024-secure-by-design-google-memory-safety.pdf` |
| Open access  | Y                                                                                                           |

**Claim.** Collects the industry figures (memory-safety bugs are about 70% of
high/critical vulnerabilities in Chrome and Android, and of Microsoft's CVEs) and argues that only
safe-by-default languages, with unsafe code confined to reviewed abstractions, reach
high assurance; hardened C++ subsets and hardware (MTE) are the bridge for legacy code.

**Verbatim quote** (p. 3):

> In essence, Safe Coding calls for unsafe constructs to be disallowed by default, and
> their use to be replaced by safe abstractions in most code, with carefully-reviewed
> exceptions.

**Relevance to sparkles.** Endorses the repo's existing rule (`@safe` by default,
`@trusted` around one operation) as the right posture for codecs: SIMD loads, pointer
casts for pixel reinterpretation and Vulkan mapping should each live behind a small,
reviewed `@trusted` primitive in `base`/`shaders`, never inline in codec loops.

**Caveats.** Vendor position paper; the 70% figures are cited from other sources
(Chromium, Android, MSRC 2019) rather than new measurement.

### Hawkes 2023 — The WebP 0day (CVE-2023-4863)

| Field        | Value                                                                    |
| ------------ | ------------------------------------------------------------------------ |
| Authors      | Ben Hawkes (Isosceles), with analysis contributions from `@mistymntncop` |
| Venue/Year   | Isosceles blog, September 21, 2023                                       |
| DOI or arXiv | none ([blog post][hawkes2023])                                           |
| Local PDF    | web source                                                               |
| Open access  | Y                                                                        |

**Claim.** Root-cause analysis of the `libwebp` `VP8L` heap overflow exploited in the
wild: Huffman tables were built into an allocation sized from precomputed worst cases
(`kTableSize`, derived with zlib's `enough`), and an _invalid_ fifth tree after four
maximal valid ones made `ReplicateValue` write past the end before the final
completeness check. Hawkes reconstructs a likely link to the BLASTPASS iMessage chain
that [Citizen Lab][blastpass] captured (Apple's CVE-2023-41064) and argues
coverage-guided fuzzing was very unlikely to find the bug.

**Verbatim quotes** (blog post):

> If a single bit is wrong at any stage, the image decoder throws an error and nothing
> bad happens.

> it's actually just denying the inputs that would cause a heap overflow instead.

**Relevance to sparkles.** Three rules for D codecs: validate a Huffman code (Kraft
completeness) **before** filling any table; size tables from the validated code, not
from a precomputed bound; and bounds-check table writes even in "proven" code (D slices
do this by default — keep them on in `checked` builds). Fuzzing alone is not the safety
argument for entropy decoders.

**Caveats.** Blog analysis by an independent researcher; the BLASTPASS ↔ CVE-2023-4863
link is presented as a theory inferred from timing, not confirmed by Apple.

### Beer and Groß 2021 — A deep dive into an NSO zero-click iMessage exploit (FORCEDENTRY)

| Field        | Value                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------------- |
| Authors      | Ian Beer, Samuel Groß (Google Project Zero)                                                                      |
| Venue/Year   | Project Zero blog, December 2021 ("Remote Code Execution"); follow-up March 2022 ("FORCEDENTRY: Sandbox Escape") |
| DOI or arXiv | none ([December 2021 post][beer2021], [March 2022 post][beer2022])                                               |
| Local PDF    | web source                                                                                                       |
| Open access  | Y                                                                                                                |

**Claim.** The FORCEDENTRY exploit (CVE-2021-30860) reached the Xpdf-derived JBIG2
decoder in CoreGraphics because ImageIO sniffs formats regardless of extension; an
integer overflow when summing referenced symbol counts under-allocated a buffer, and
JBIG2's refinement operators (AND/OR/XOR/XNOR) were then used as logic gates to build a
small computer out of more than 70,000 segment commands. The follow-up shows that this
weird machine then loaded a sandbox escape built only from logic bugs, which pointer
authentication and memory tagging do not stop.

**Verbatim quotes** (December 2021 post, twice; March 2022 post):

> Using this "fake gif" trick, over 20 image codecs are suddenly part of the iMessage
> zero-click attack surface

> JBIG2 doesn't have scripting capabilities, but when combined with a vulnerability, it
> does have the ability to emulate circuits of arbitrary logic gates operating on
> arbitrary memory.

> It's notable for using only logic bugs.

**Relevance to sparkles.** Content sniffing multiplies attack surface: `sparkles`
dispatch should let callers allow-list codecs, and obscure or legacy formats should be
opt-in builds. Count arithmetic (`numSyms += …`) must use checked arithmetic
(`core.checkedint` or saturating helpers) before allocation. It is also the canonical
illustration of LangSec's "weird machine" — a decoder's own operators become the
exploit's instruction set — and the sandbox-escape half shows why embedders may still
want decoding in a separate least-privilege process.

**Caveats.** Post-hoc analysis of one closed-source target; generalisations to other
decoders are argued, not measured.

## Thread synthesis

**Consensus.**

- Untested hand-written parsers fail on hostile input at rates that surprise their
  authors, and unchecked array ranges were among the commonest causes in the first
  fuzzing study (Miller et al.); the remedy is structural, not more care.
- Input handling should be a separate, complete recognition stage producing typed
  values; downstream code never sees raw bytes (LangSec papers, Nail, EverParse, Wuffs's
  two-phase API).
- Generating parsers from a declarative description beats hand-written parsing, and the
  description pays for itself again as an encoder, a fuzzer generator and a round-trip
  oracle (Nail, Narcissus, EverParse3D, FormatFuzzer).
- Memory-safety bugs dominate exploitable vulnerabilities in C/C++ codecs, and both
  in-the-wild image exploits here are allocation-size/write-size disagreements in
  heavily fuzzed code (Rebert and Kern, Hawkes, Beer and Groß, Bangert and Zeldovich).
- Fuzzing is only as good as its generator, its scheduler and its oracle: structure-
  or grammar-aware generation to get past consistency checks (Holler et al.,
  FormatFuzzer), schedules that favour rare paths (Böhme et al. 2016), sanitizers and
  differential comparison as oracles (ASan, Csmith, NEZHA), and continuous operation by
  the code owners (OSS-Fuzz); Manès et al. give these one vocabulary.
- Fuzzing finds many bugs cheaply but its evidence is weak without statistics and ground
  truth, and it does not reach deep, constraint-heavy states (Klees, Magma, Böhme et
  al. 2021, Hawkes).

**Disagreements and tensions.**

- _Assurance allocation._ The verified-parser line treats safety as proved and leaves
  testing to interoperability; Hawkes argues from `libwebp` that fuzzing was asked to
  carry an assurance it cannot deliver for jointly constrained bugs; Klees et al. show
  that even comparative fuzzing claims rarely survive scrutiny. The positions are
  compatible but budget differently: proof or generation for the structural layer,
  targeted adversarial tests for constrained numeric kernels such as Huffman table
  construction, and fuzzing as continuous regression rather than a one-off argument.
- _Proof versus runtime checks._ EverParse/Narcissus/Wuffs remove checks by proof;
  Google's position, Miller's "range checking full-time" and D's default rely on
  runtime bounds checks plus a small unsafe core. For entropy decoders the cost of
  bounds checks is real but no entry measures it on identical decoder workloads.
- _Strictness versus compatibility._ LangSec's "most restrictive input" conflicts with
  the de facto permissive behaviour of browser decoders; Daedalus's PDF work had to
  model the implicit specification of existing readers, and differential testing
  (Csmith, NEZHA) has no clean oracle when references legitimately differ in leniency.
- _Where LangSec stops._ Recognition before processing is feasible for container
  syntax but not for entropy-coded payloads, where validity is only known while
  decoding; none of the verified-parser papers handle Huffman/arithmetic-coded data.

**Open problems.**

- Verified or proof-carrying _entropy decoders_ (Huffman, ANS, CABAC) at SIMD speed.
- Resource safety (work and memory per input byte) as a checked property, not a fuzzer
  timeout; the LangSec papers name resource exhaustion but no entry gives a budgeting
  method.
- Differential oracles for lossy codecs, where conforming decoders legitimately differ
  within tolerance.
- Double-fetch-free parsing from GPU-visible or shared memory, and more generally
  carrying the CPU recogniser's guarantees across the CPU-to-GPU boundary, where a
  shader re-reads structures the CPU validated.

**What a D implementation should take from this.**

- Split every codec into `probe` (header/container recogniser returning an
  `Expected!(ImageInfo, DecodeError)` whose type only the recogniser can construct) and
  `decode` into a caller-owned buffer; the caller checks `ImageInfo` against limits
  before allocating, possibly directly in a Vulkan staging buffer.
- Keep the decoder core `@safe pure nothrow @nogc`, allocation-free and Sans-I/O
  (resumable state machine), so it runs unchanged under `event-horizon` or blocking
  reads.
- Describe container syntax (PNG chunks, RIFF, ISOBMFF boxes, TIFF IFDs) in `wired`
  with dependent length fields and explicit sub-stream extents; derive parser, writer,
  round-trip property tests and a structure-aware fuzz generator from the same
  description.
- Use checked arithmetic for every size computation (`width * height * bpp`, symbol
  counts, table sizes) and validate Huffman codes for completeness before building
  tables; never size from a precomputed worst case alone, and give table builders unit
  tests over systematically invalid code-length sets, not only file-level fuzzing.
- Never let an `assert` carry memory safety: a write sized from input is guarded by a
  check that returns `DecodeError`, and bounds checks stay on in every build that
  decodes hostile input (the repository ships `checked`, never `release`).
- Budget work and memory from declared dimensions before allocating or looping (total
  pixels, output bytes, frames, operations), and charge each repeated or aliased visit
  (overlapping `iloc` extents, reused JBIG2 symbols) against the budget again.
- Confine `@trusted` to a few reviewed primitives (SIMD load/store, pixel
  reinterpretation, mapped-memory views); copy-then-validate scalars read from shared or
  mapped memory.
- Make codec dispatch allow-listed, with legacy/obscure formats opt-in, and expose
  resource limits (max pixels, max bytes, max frames) in the public API.
- Fuzz continuously from the first decoder: one deterministic bytes-in target per
  format, the test suite as seed corpus, per-format dictionaries, ASan builds, and every
  crash minimised into a permanent regression test; test with differential oracles
  against pinned reference decoders (`libpng`, `libjpeg-turbo`, `libwebp`, Wuffs) and
  the scalar D path, seeded with historical CVE inputs.
- Report fuzzing results to Klees et al.'s standard (trials, budgets, seeds, distinct
  root causes), and never present coverage or crash-free hours as a safety proof.

## Sources

- Papers: [Miller et al. 1990][miller1990-doi], [Sassaman et al. 2011][sassaman2011],
  [Sassaman et al. 2013][sassaman2013-doi] ([TR][sassaman2013-tr]),
  [Momot et al. 2016][momot2016-doi], [Bratus et al. 2017][bratus2017],
  [Bangert and Zeldovich 2014][nail-usenix], [Ramananandro et al. 2019][everparse-usenix],
  [Swamy et al. 2022][swamy2022-doi], [Delaware et al. 2019][delaware2019-doi],
  [Diatchki et al. 2024][diatchki2024-doi], [Yang et al. 2011][yang2011-doi],
  [Petsios et al. 2017][petsios2017-doi], [Holler et al. 2012][holler2012],
  [Serebryany et al. 2012][asan-usenix], [Böhme et al. 2016][bohme2016-doi]
  ([TSE][bohme2016-tse]), [Klees et al. 2018][klees2018-doi],
  [Ding and Le Goues 2021][ding2021-doi], [Hazimeh et al. 2020][magma-doi],
  [Dutra et al. 2023][formatfuzzer-doi], [Manès et al. 2019][manes2019-doi]
  ([arXiv][manes2019-arxiv]), [Böhme et al. 2021][bohme2021-doi],
  [Rebert and Kern 2024][rebert2024-page].
- Talk: [Serebryany 2017, OSS-Fuzz][ossfuzz2017].
- Primary web sources: [Wuffs `README.md`][wuffs-readme],
  [Wuffs memory-safety note][wuffs-memsafety], [Tao 2021][tao2021],
  [Hawkes, "The WebP 0day"][hawkes2023], [Citizen Lab, BLASTPASS][blastpass],
  [Beer and Groß, FORCEDENTRY RCE][beer2021],
  [Beer and Groß, FORCEDENTRY sandbox escape][beer2022].
- Repo context: [Writing Research Docs][research-docs].

<!-- References -->

[miller1990-doi]: https://doi.org/10.1145/96267.96279
[miller1990]: https://www.paradyn.org/papers/fuzz.pdf
[sassaman2011]: https://www.cs.dartmouth.edu/~sergey/langsec/papers/Sassaman.pdf
[sassaman2013-doi]: https://doi.org/10.1109/JSYST.2012.2222000
[sassaman2013-tr]: https://www.cs.dartmouth.edu/~sergey/langsec/papers/langsec-tr.pdf
[momot2016-doi]: https://doi.org/10.1109/SecDev.2016.019
[bratus2017]: https://www.usenix.org/publications/login/spring2017/bratus
[nail-usenix]: https://www.usenix.org/conference/osdi14/technical-sessions/presentation/bangert
[everparse-usenix]: https://www.usenix.org/conference/usenixsecurity19/presentation/delignat-lavaud
[swamy2022-doi]: https://doi.org/10.1145/3519939.3523708
[delaware2019-doi]: https://doi.org/10.1145/3341686
[delaware2019-arxiv]: https://arxiv.org/abs/1803.04870
[diatchki2024-doi]: https://doi.org/10.1145/3656410
[yang2011-doi]: https://doi.org/10.1145/1993498.1993532
[yang2011]: https://www.cs.utah.edu/~regehr/papers/pldi11-preprint.pdf
[petsios2017-doi]: https://doi.org/10.1109/SP.2017.27
[holler2012]: https://www.usenix.org/conference/usenixsecurity12/technical-sessions/presentation/holler
[asan-usenix]: https://www.usenix.org/conference/atc12/technical-sessions/presentation/serebryany
[bohme2016-doi]: https://doi.org/10.1145/2976749.2978428
[bohme2016-tse]: https://doi.org/10.1109/TSE.2017.2785841
[ossfuzz2017]: https://www.usenix.org/conference/usenixsecurity17/technical-sessions/presentation/serebryany
[klees2018-doi]: https://doi.org/10.1145/3243734.3243804
[klees2018-arxiv]: https://arxiv.org/abs/1808.09700
[ding2021-doi]: https://doi.org/10.1109/MSR52588.2021.00026
[ding2021-arxiv]: https://arxiv.org/abs/2103.11518
[magma-doi]: https://doi.org/10.1145/3428334
[magma-arxiv]: https://arxiv.org/abs/2009.01120
[formatfuzzer-doi]: https://doi.org/10.1145/3628157
[formatfuzzer-arxiv]: https://arxiv.org/abs/2109.11277
[manes2019-doi]: https://doi.org/10.1109/TSE.2019.2946563
[manes2019-arxiv]: https://arxiv.org/abs/1812.00140
[bohme2021-doi]: https://doi.org/10.1109/MS.2020.3016773
[rebert2024-page]: https://research.google/pubs/secure-by-design-googles-perspective-on-memory-safety/
[wuffs-readme]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/README.md
[wuffs-memsafety]: https://github.com/google/wuffs/blob/4be865da258c4b5e6d3e716fd4f36be016496a46/doc/note/memory-safety.md
[tao2021]: https://nigeltao.github.io/blog/2021/fastest-safest-png-decoder.html
[hawkes2023]: https://blog.isosceles.com/the-webp-0day/
[blastpass]: https://citizenlab.ca/blastpass-nso-group-iphone-zero-click-zero-day-exploit-captured-in-the-wild/
[beer2021]: https://projectzero.google/2021/12/a-deep-dive-into-nso-zero-click.html
[beer2022]: https://projectzero.google/2022/03/forcedentry-sandbox-escape.html
[research-docs]: ../../../guidelines/research-docs.md
