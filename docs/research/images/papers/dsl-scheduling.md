# Papers: image-processing DSLs and scheduling

The literature that separates **what** an image pipeline computes from **how** it is
laid out in loops, memory and hardware, and the line of work that then tries to choose
that layout automatically.

| Field              | Value                                                                                                                                   |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| **Thread**         | `dsl-scheduling`                                                                                                                        |
| **Scope**          | Image-processing DSLs; algorithm/schedule separation; fusion, tiling, vectorisation; autoschedulers; hardware (line-buffered) pipelines |
| **Entries**        | 19                                                                                                                                      |
| **Last reviewed:** | October 28, 2026                                                                                                                        |

> [!NOTE]
> Quote page numbers ("p. N") are **PDF page indices** of the local copy, counted from
> the first page of the file, not the printed journal page numbers.

## Why this thread matters to sparkles

`sparkles:{image,video}` wants **generic image abstractions** that stay fast: a pixel
kernel written once must run as scalar D, as runtime-dispatched **SIMD** (the
`blake3_simd.d` `@target` pattern) and as a `Vulkan` **GPU compute** shader through
`sparkles:shaders`. Every paper here answers some part of the question that design
must settle first: is the unit of reuse a _loop_ (a hand-written kernel), a _range
pipeline_ (lazy composition, no control over locality), or a _function over an
integer domain plus a separate schedule_? The thread also touches the **storage-to-GPU**
path (the hardware-pipeline papers are about streaming pixels through bounded
line buffers, which is the same shape as decoding rows from an `io_uring` read into a
staging buffer), **hostile input** (bounds inference decides how far a stencil reads
past an edge, and `Exo` turns that into a static memory-safety proof), and **codec
architecture** (`Darkroom`/`Rigel`'s rate model is how a decoder that emits rows at one
rate feeds a resampler that consumes them at another). Colour is not addressed by this
thread.

## Annotated bibliography

### Functional Images (Elliott 2003)

| Field        | Value                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------- |
| Authors      | Conal Elliott                                                                               |
| Venue/Year   | Chapter 7 of _The Fun of Programming_ (Gibbons and de Moor, eds.), Palgrave Macmillan, 2003 |
| DOI or arXiv | [10.1007/978-1-349-91518-7_7][doi-elliott]                                                  |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/elliott2003-functional-images.pdf`          |
| Open access  | Y (author's copy, [conal.net][pdf-elliott]; the file also carries the book's front matter)  |

**Claim.** An image is modelled as a function from continuous, infinite 2D space to a
value (colour with alpha, a boolean region, anything), so transforms, masks and
animations are ordinary function composition in a `Haskell`-embedded language (`Pan`).
The chapter is about the semantic model; `Pan`'s compiler to efficient code is mentioned
but not the subject.

**Verbatim quote** (p. 9):

> Pan's model of images is simply functions from infinite, continuous 2D space to colours with partial opacity.

**Relevance to sparkles.** This is the denotation `Halide` later restricts to integer
domains. For D it argues that the _semantic_ image type can be a callable (`Image!T`
as `T delegate(Point)` or a struct with `opCall`) whose domain is unbounded, with
bounds and storage attached only when a consumer materialises it. A lazy `map`/`zip`
pipeline in `sparkles` is this model; it is the right reference interface and the
oracle for scheduled variants.

**Caveats.** No performance claims; continuous domains do not map to codecs or SIMD
without resampling decisions the model leaves out. The implementation described
required a Microsoft `C++` compiler at the time (footnote on the same page).
`Haskell`-specific.

### Decoupling Algorithms from Schedules for Easy Optimization of Image Processing Pipelines (Ragan-Kelley et al. 2012)

| Field        | Value                                                                                                     |
| ------------ | --------------------------------------------------------------------------------------------------------- |
| Authors      | Jonathan Ragan-Kelley, Andrew Adams, Sylvain Paris, Marc Levoy, Saman Amarasinghe, Frédo Durand           |
| Venue/Year   | ACM Transactions on Graphics 31(4) (SIGGRAPH 2012)                                                        |
| DOI or arXiv | [10.1145/2185520.2185528][doi-halide12]                                                                   |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/raganKelley2012-decoupling-algorithms-from-schedules.pdf` |
| Open access  | Y ([author page][pdf-halide12])                                                                           |

**Claim.** The first `Halide` paper: a feed-forward image pipeline is written as pure
functions over an infinite integer grid, and a separate per-function schedule chooses
tiling, fusion, recomputation versus storage, vectorisation and parallelism. The same
algorithm then compiles for ARM, x86 and GPUs with state-of-the-art performance, and the
3×3 box filter in its Figure 1 matches a hand-vectorised, multithreaded, tiled and fused
`C++` version that is more than 10× faster than the naive loops.

**Verbatim quote** (p. 1):

> images and intermediate buffers become functions over an infinite integer domain, with no explicit storage or boundary conditions.

**Relevance to sparkles.** The defining split for a generic image layer. "No boundary
conditions" in the algorithm means edge handling is an explicit wrapper function
(clamp, mirror, constant), which is also where a hostile-input-safe design puts its
bounds: a decoder's output view is the only thing with a finite domain. In D the
algorithm can be ordinary (CTFE-visible) functions and the schedule a compile-time
value consumed by a template that emits the loop nest.

**Caveats.** Superseded in detail by the PLDI 2013 model; the scheduling vocabulary
(`chunk`, `root`, `inline`) was renamed later. Benchmarks are on 2011-era hardware.

### Halide: A Language and Compiler for Optimizing Parallelism, Locality, and Recomputation in Image Processing Pipelines (Ragan-Kelley et al. 2013)

| Field        | Value                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| Authors      | Jonathan Ragan-Kelley, Connelly Barnes, Andrew Adams, Sylvain Paris, Frédo Durand, Saman Amarasinghe |
| Venue/Year   | PLDI 2013, pp. 519–530                                                                               |
| DOI or arXiv | [10.1145/2491956.2462176][doi-halide13]                                                              |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/raganKelley2013-halide.pdf`                          |
| Open access  | Y ([author page][pdf-halide13])                                                                      |

**Claim.** Formalises the schedule space as two choices per stage, the _call schedule_
(at which loop level of the consumer a producer is computed and stored) and the
_domain order_ (split, reorder, vectorise, parallelise), and shows that the trade-off
between parallelism, locality and redundant work is inherent to stencil pipelines.
Bounds of every intermediate are inferred by interval analysis, and a stochastic
autotuner searches schedules.

**Verbatim quotes** (p. 1; p. 5; p. 11):

> there is a fundamental tension between parallelism, locality, and introducing redundant recomputation of shared values.

> Our model considers only axis-aligned bounding regions, not general polytopes—a practical simplification for image processing and many other applications.

> These examples took between 2 hours and 2 days to tune (from 10s to 100s of generations).

**Relevance to sparkles.** The axis-aligned-box choice is the one to copy: a D bounds
inference over rectangles is a small CTFE-friendly interval analysis and covers
resampling, pyramids and stencils, while polyhedra would need an external library. The
compute-at/store-at pair maps directly onto `sparkles.base.buffer` decisions (an
`InlineBuffer` per tile versus a `HeapBuffer` per image). The tuning times explain why
a library cannot ship autotuning as its default path.

**Caveats.** Feed-forward pipelines only (no data-dependent control flow across
stages); the genetic-algorithm autotuner was replaced by later work in this list.

### Halide: Decoupling Algorithms from Schedules for High-Performance Image Processing (Ragan-Kelley et al. 2018)

| Field        | Value                                                                                                                            |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Jonathan Ragan-Kelley, Andrew Adams, Dillon Sharlet, Connelly Barnes, Sylvain Paris, Marc Levoy, Saman Amarasinghe, Frédo Durand |
| Venue/Year   | Communications of the ACM 61(1), pp. 106–115, January 2018 (Research Highlights)                                                 |
| DOI or arXiv | [10.1145/3150211][doi-halide18]                                                                                                  |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/raganKelley2018-halide-cacm.pdf`                                                 |
| Open access  | Y ([MIT CSAIL copy][pdf-halide18])                                                                                               |

**Claim.** A consolidated retelling of the 2012 and 2013 papers for a general audience,
with the deployment record after four years of open-source use and targets that now
include specialised image processors. It is the best single introduction to the model.

**Verbatim quote** (p. 1):

> Halide has been public and open source for over four years, during which it has been used by hundreds of programmers to deploy code to tens of thousands of servers and hundreds of millions of phones, processing billions of images every day.

**Relevance to sparkles.** Evidence that the split survives production use, which
matters when deciding whether `sparkles:image` algorithms should carry a schedule
parameter at all rather than fixed kernels.

**Caveats.** A survey of the authors' own work, not new results; deployment numbers
are self-reported. Crossref dates the online issue December 27, 2017.

### PolyMage: Automatic Optimization for Image Processing Pipelines (Mullapudi, Vasista, Bondhugula 2015)

| Field        | Value                                                                       |
| ------------ | --------------------------------------------------------------------------- |
| Authors      | Ravi Teja Mullapudi, Vinay Vasista, Uday Bondhugula                         |
| Venue/Year   | ASPLOS 2015, pp. 429–443                                                    |
| DOI or arXiv | [10.1145/2694344.2694364][doi-polymage]                                     |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/mullapudi2015-polymage.pdf` |
| Open access  | Y (author copy via [Wayback snapshot][pdf-polymage]; the lab URL now 404s)  |

**Claim.** A `Python`-embedded, `Halide`-inspired DSL whose compiler chooses fusion
groups, overlapped tile shapes and storage reduction itself, using the polyhedral
model and a cost model instead of a user schedule. It reports up to 1.81× over
hand-tuned `Halide` schedules on multicore CPUs.

**Verbatim quote** (p. 1):

> To the best of our knowledge, this is the first model-driven compiler for image processing pipelines that performs complex fusion, tiling, and storage optimization automatically.

**Relevance to sparkles.** Shows that overlapped (redundant-halo) tiling plus a
greedy fusion heuristic gets most of the benefit without search. A D pipeline builder
could compute halo sizes at compile time from declared stencil footprints and pick
tile sizes from `hw_caps` cache data, with no user schedule.

**Caveats.** CPU-only evaluation; relies on a polyhedral toolchain (`isl`) that a D
library would not want as a dependency.

### Automatically Scheduling Halide Image Processing Pipelines (Mullapudi et al. 2016)

| Field        | Value                                                                                              |
| ------------ | -------------------------------------------------------------------------------------------------- |
| Authors      | Ravi Teja Mullapudi, Andrew Adams, Dillon Sharlet, Jonathan Ragan-Kelley, Kayvon Fatahalian        |
| Venue/Year   | ACM Transactions on Graphics 35(4) (SIGGRAPH 2016)                                                 |
| DOI or arXiv | [10.1145/2897824.2925952][doi-mullapudi16]                                                         |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/mullapudi2016-automatically-scheduling-halide.pdf` |
| Open access  | Y (author copy via [Wayback snapshot][pdf-mullapudi16])                                            |

**Claim.** An analytic autoscheduler built into `Halide`: it reuses the compiler's
bounds analysis to group stages, choose tile sizes and inline cheap stages, guided by
a simple cost model of arithmetic and memory traffic. It runs in seconds and is
competitive with expert schedules on CPUs and GPUs.

**Verbatim quote** (p. 1):

> The algorithm does not require costly (and often impractical) auto-tuning, and, in seconds, generates schedules for a broad set of image processing benchmarks that are performance-competitive with, and often better than, schedules manually authored by expert Halide developers on server and mobile CPUs, as well as GPUs.

**Relevance to sparkles.** The realistic target for a library: a deterministic
heuristic over inferred bounds, cheap enough to run at compile time (CTFE) or at
pipeline construction. It needs the user to give estimated output sizes, a constraint
a D API can make a required parameter.

**Caveats.** Later work in this list reports it is roughly half as fast as the learned
scheduler; GPU support was limited; the cost model is hand-tuned to 2016 machines.

### Learning to Optimize Halide with Tree Search and Random Programs (Adams et al. 2019)

| Field        | Value                                                                                                                                                                       |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Andrew Adams, Karima Ma, Luke Anderson, Riyadh Baghdadi, Tzu-Mao Li, Michaël Gharbi, Benoit Steiner, Steven Johnson, Kayvon Fatahalian, Frédo Durand, Jonathan Ragan-Kelley |
| Venue/Year   | ACM Transactions on Graphics 38(4), Article 121 (SIGGRAPH 2019)                                                                                                             |
| DOI or arXiv | [10.1145/3306346.3322967][doi-adams19]                                                                                                                                      |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/adams2019-learning-to-optimize-halide.pdf`                                                                                  |
| Open access  | Y ([halide-lang.org][pdf-adams19])                                                                                                                                          |

**Claim.** A beam search over a much larger schedule space, scored by a small neural
cost model over hand-designed features, which is trained on benchmarks of hundreds of
thousands of randomly generated pipelines. Without autotuning it averages almost 2×
the 2016 autoscheduler and is the first to beat human experts on average.

**Verbatim quotes** (p. 1; p. 10):

> We train the cost model by generating and featurizing hundreds of thousands of random programs and schedules.

> One major limitation of our system is that in order to evaluate a cost it must reason in terms of constant-valued properties of the algorithm and schedule.

**Relevance to sparkles.** The random-program generator is the transferable idea: the
same generator doubles as a differential-testing corpus for any scheduled D kernel
against its reference (scalar) form. The constant-size limitation argues for
specialising pipelines per output-size class rather than one generic schedule.

**Caveats.** Building the training set means benchmarking hundreds of thousands of
programs on the target machine, so a new architecture needs new data; features are
hand-engineered; the user must supply a concrete output size to optimise for.

### Efficient Automatic Scheduling of Imaging and Vision Pipelines for the GPU (Anderson et al. 2021)

| Field        | Value                                                                                |
| ------------ | ------------------------------------------------------------------------------------ |
| Authors      | Luke Anderson, Andrew Adams, Karima Ma, Tzu-Mao Li, Tian Jin, Jonathan Ragan-Kelley  |
| Venue/Year   | Proc. ACM Program. Lang. 5 (OOPSLA 2021), Article 109                                |
| DOI or arXiv | [10.1145/3485486][doi-anderson21] / [arXiv:2012.07145][arxiv-anderson21]             |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/anderson2021-gpu-autoscheduling.pdf` |
| Open access  | Y (arXiv v2)                                                                         |

**Claim.** Extends search-based autoscheduling to GPUs, where the schedule must assign
loops to blocks, threads and shared memory. Scalability comes from freezing cheap
stages early, sampling structurally similar schedules hierarchically and memoising
partial schedules; schedules average 1.7× over prior automatic methods.

**Verbatim quote** (p. 23):

> Register spilling often has a large performance impact on the GPU, but the spilling behavior of the downstream PTX compiler can be unpredictable.

**Relevance to sparkles.** For `sparkles:shaders` compute (M10), the lesson is that
the GPU mapping decision (workgroup size, per-invocation tile, shared-memory staging)
is a schedule, and its cost depends on a downstream compiler sparkles does not control
(`SPIR-V` to vendor ISA). A D design should keep the workgroup shape a parameter that
can be measured per device, not a constant baked into the kernel.

**Caveats.** `CUDA`/`PTX` only; no `Vulkan` or mobile GPUs; reductions (`rfactor`) are
outside the searched space.

### Differentiable Programming for Image Processing and Deep Learning in Halide (Li et al. 2018)

| Field        | Value                                                                             |
| ------------ | --------------------------------------------------------------------------------- |
| Authors      | Tzu-Mao Li, Michaël Gharbi, Andrew Adams, Frédo Durand, Jonathan Ragan-Kelley     |
| Venue/Year   | ACM Transactions on Graphics 37(4), Article 139 (SIGGRAPH 2018)                   |
| DOI or arXiv | [10.1145/3197517.3201383][doi-li18]                                               |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/li2018-differentiable-halide.pdf` |
| Open access  | Y ([author page][pdf-li18])                                                       |

**Claim.** Adds reverse-mode automatic differentiation to `Halide`, converting the
scatters that naive adjoints of gather stencils produce back into gathers to keep
parallelism, and schedules the generated gradient code automatically; checkpointing is
expressed with existing compute-at primitives.

**Verbatim quote** (p. 1):

> A key challenge is to structure the gradient code to retain parallelism.

**Relevance to sparkles.** Peripheral to codecs, but relevant to the generic-algorithm
layer: if stages are pure functions over integer domains, their adjoints are derivable
mechanically, and the same schedule vocabulary covers both directions. A sign that the
function-over-domain representation is worth keeping introspectable at compile time.

**Caveats.** Out of scope for a first `sparkles:image` milestone; gradients matter
only once `sparkles` trains or fits image operators, which no planned codec or
display path does.

### Darkroom: Compiling High-Level Image Processing Code into Hardware Pipelines (Hegarty et al. 2014)

| Field        | Value                                                                                                                                     |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | James Hegarty, John Brunhaver, Zachary DeVito, Jonathan Ragan-Kelley, Noy Cohen, Steven Bell, Artem Vasilyev, Mark Horowitz, Pat Hanrahan |
| Venue/Year   | ACM Transactions on Graphics 33(4) (SIGGRAPH 2014)                                                                                        |
| DOI or arXiv | [10.1145/2601097.2601174][doi-darkroom]                                                                                                   |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/hegarty2014-darkroom.pdf`                                                                 |
| Open access  | Y (low-resolution author copy via [Wayback snapshot][pdf-darkroom])                                                                       |

**Claim.** By restricting stages to fixed-offset stencils with no recursion, a
pipeline compiles to a line-buffered streaming architecture (the shape of a camera
ISP), with every intermediate held on chip. Minimising line-buffer size becomes an
integer linear program; the output is ASIC/FPGA HDL or fast CPU code.

**Verbatim quotes** (p. 2; p. 3; p. 1):

> Darkroom restricts image operations to static, fixed size windows, or stencils.

> Affine indices like I(x\*2,y\*2) are not allowed.

> We formulate the problem of optimally scheduling line-buffered pipelines to minimize buffering as an integer linear program.

**Relevance to sparkles.** The streaming model is exactly the one a row-streaming
decoder (`PNG`, baseline `JPEG` MCU rows) needs: a consumer that never holds the whole
image, with a statically known number of buffered rows per stage. In D the stencil
footprints can be template parameters, so the line-buffer depths (and so the memory
bound for hostile inputs) are computed at compile time rather than by an ILP.

**Caveats.** Single-rate only (no downsampling), which rules out pyramids and chroma
subsampling; the CPU path reaches only tens of megapixels per second; ASIC results
are simulated (45 nm).

### Rigel: Flexible Multi-Rate Image Processing Hardware (Hegarty et al. 2016)

| Field        | Value                                                                                               |
| ------------ | --------------------------------------------------------------------------------------------------- |
| Authors      | James Hegarty, Ross Daly, Zachary DeVito, Jonathan Ragan-Kelley, Mark Horowitz, Pat Hanrahan        |
| Venue/Year   | ACM Transactions on Graphics 35(4) (SIGGRAPH 2016)                                                  |
| DOI or arXiv | [10.1145/2897824.2925892][doi-rigel]                                                                |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/hegarty2016-rigel.pdf`                              |
| Open access  | Y (low-resolution author copy via [Wayback snapshot][pdf-rigel]; the local file is full-resolution) |

**Claim.** Lifts `Darkroom`'s single-rate restriction with a multi-rate architecture
built on synchronous dataflow: modules declare token rates, the compiler solves firing
rates, and pyramids, sparse computation and space-time trade-offs become expressible.
It synthesises FPGA designs running at 20–436 megapixels per second.

**Verbatim quote** (p. 1):

> Recent work on hardware synthesis of high-level image processing languages demonstrated that a single-rate pipeline of stencil kernels can be synthesized into hardware with provably minimal buffering. Unfortunately, few advanced image processing or vision algorithms fit into this highly-restricted programming model.

**Relevance to sparkles.** Synchronous-dataflow rates are the right vocabulary for a
video or codec pipeline on `sparkles:event-horizon`: a 4:2:0 chroma plane is a stage
at a quarter rate, a scaler changes rate, and static rates give bounded queues
between fibers. The paper is the strongest argument for typing stage rates rather than
discovering them at run time.

**Caveats.** FPGA-specific: the construction library is embedded in `Lua` and lowers
to `Verilog`, with `Terra` used only for a cycle-accurate simulator; data-dependent
rates are handled only through specific sparse primitives.

### Hipacc: A Domain-Specific Language and Compiler for Image Processing (Membarth et al. 2016)

| Field        | Value                                                                                     |
| ------------ | ----------------------------------------------------------------------------------------- |
| Authors      | Richard Membarth, Oliver Reiche, Frank Hannig, Jürgen Teich, Mario Körner, Wieland Eckert |
| Venue/Year   | IEEE Transactions on Parallel and Distributed Systems 27(1), pp. 210–224, 2016            |
| DOI or arXiv | [10.1109/TPDS.2015.2394802][doi-hipacc]                                                   |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/membarth2016-hipacc.pdf`                  |
| Open access  | Y (author version, [Saarland][pdf-hipacc])                                                |

**Claim.** A `C++`-embedded DSL of point, local (masked stencil) and global (reduction)
operators, source-to-source compiled to `CUDA`, `OpenCL` and `Renderscript`. Boundary
modes and masks are first-class, so the compiler generates specialised border variants
and reaches the memory-bandwidth roofline.

**Verbatim quote** (p. 1):

> Exploiting the captured domain knowledge, we can generate specialized algorithm variants that reach the maximal achievable performance due to the peak memory bandwidth.

**Relevance to sparkles.** The alternative to an explicit schedule: a small fixed
operator taxonomy (point/local/global) with declared boundary handling, from which the
compiler picks the variant. It fits D's design-by-introspection style (an operator
declares its footprint and boundary mode; the dispatcher specialises), and its
border-region splitting is how a kernel avoids per-pixel bounds checks while staying
safe on hostile dimensions.

**Caveats.** Single-kernel focus with limited cross-stage fusion; `Renderscript` is
dead; GPU-only targets in this paper (FPGA came later).

### Tiramisu: A Polyhedral Compiler for Expressing Fast and Portable Code (Baghdadi et al. 2019)

| Field        | Value                                                                                                                                                     |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Riyadh Baghdadi, Jessica Ray, Malek Ben Romdhane, Emanuele Del Sozzo, Abdurrahman Akkas, Yunming Zhang, Patricia Suriana, Shoaib Kamil, Saman Amarasinghe |
| Venue/Year   | CGO 2019, pp. 193–205                                                                                                                                     |
| DOI or arXiv | [10.1109/CGO.2019.8661197][doi-tiramisu] / [arXiv:1804.10694][arxiv-tiramisu]                                                                             |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/baghdadi2019-tiramisu.pdf`                                                                                |
| Open access  | Y (arXiv v5)                                                                                                                                              |

**Claim.** A polyhedral compiler with a `Halide`-like scheduling language, extended with
explicit commands for communication, synchronisation and buffer placement in the
memory hierarchy, targeting CPUs, GPUs, distributed machines and FPGAs. Its IR has four
layers so that algorithm, loop transformation, data layout and communication are
specified independently.

**Verbatim quote** (p. 2):

> explicitly divides the intermediate representation into four layers designed to hide the complexity and large variety of execution platforms by separating the architecture-independent algorithm from code transformations, data layout, and communication.

**Relevance to sparkles.** The four-way split is a useful checklist for a D image API:
algorithm, iteration order, storage layout (planar/interleaved/tiled, which `sparkles`
must choose for codecs anyway), and data movement (host-to-device copies, which on
`Vulkan` are explicit). `Halide` merges the last two into the schedule; `Tiramisu`
shows they can be separate parameters.

**Caveats.** Polyhedral machinery (`isl`) is a heavy dependency; benchmarks lean toward
linear algebra and deep learning; scheduling is still manual.

### TVM: An Automated End-to-End Optimizing Compiler for Deep Learning (Chen et al. 2018)

| Field        | Value                                                                                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Authors      | Tianqi Chen, Thierry Moreau, Ziheng Jiang, Lianmin Zheng, Eddie Yan, Meghan Cowan, Haichen Shen, Leyuan Wang, Yuwei Hu, Luis Ceze, Carlos Guestrin, Arvind Krishnamurthy |
| Venue/Year   | OSDI 2018 (USENIX), pp. 578–594                                                                                                                                          |
| DOI or arXiv | [arXiv:1802.04799][arxiv-tvm] (no DOI; [USENIX page][usenix-tvm])                                                                                                        |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/chen2018-tvm.pdf`                                                                                                        |
| Open access  | Y (arXiv v3)                                                                                                                                                             |

**Claim.** Carries `Halide`'s compute/schedule split to tensor operators, adds
graph-level operator fusion, tensorisation for hardware intrinsics and latency hiding
for accelerators, and replaces hand tuning with a learned cost model that ranks
candidate schedules.

**Verbatim quote** (p. 1):

> It also automates optimization of low-level programs to hardware characteristics by employing a novel, learning-based cost modeling method for rapid exploration of code optimizations.

**Relevance to sparkles.** _Tensorisation_ (declaring a hardware intrinsic as a
pattern the scheduler may substitute) is the analogue of the `@target` SIMD variants
in `sparkles:base`: the kernel names a micro-operation, and per-target bodies provide
it. For images, a 3×3 convolution or a colour-matrix multiply is such a micro-op.

**Caveats.** Deep-learning workloads, not image pipelines; the search needs on-device
measurement; its schedule search is driven by hand-written per-operator templates, the
restriction `Ansor` (below) removes.

### Ansor: Generating High-Performance Tensor Programs for Deep Learning (Zheng et al. 2020)

| Field        | Value                                                                                                                                                        |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Authors      | Lianmin Zheng, Chengfan Jia, Minmin Sun, Zhao Wu, Cody Hao Yu, Ameer Haj-Ali, Yida Wang, Jun Yang, Danyang Zhuo, Koushik Sen, Joseph E. Gonzalez, Ion Stoica |
| Venue/Year   | OSDI 2020 (USENIX), pp. 863–879                                                                                                                              |
| DOI or arXiv | [arXiv:2006.06762][arxiv-ansor] (no DOI; [USENIX page][usenix-ansor])                                                                                        |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/zheng2020-ansor.pdf`                                                                                         |
| Open access  | Y (arXiv v5)                                                                                                                                                 |

**Claim.** Template-based (`TVM`) and pruning-based (the 2019 `Halide` autoscheduler)
search both miss good programs because their spaces are too narrow or they judge
incomplete programs. `Ansor` builds the space automatically from the computation
definition as two levels, _sketches_ (high-level loop and fusion structure, derived by
a few rules) and _annotations_ (tile sizes, parallel, unroll and vectorisation
choices, sampled at random), then refines complete sampled programs by evolutionary
search under a learned cost model, with a task scheduler that allocates tuning time
across the subgraphs of a network. It reports up to 3.8×, 2.6× and 1.7× over the state
of the art on Intel CPU, ARM CPU and NVIDIA GPU.

**Verbatim quotes** (p. 1; p. 14):

> existing approaches fail to capture many effective optimization combinations, because they rely on either predefined manually-written templates (e.g., TVM [12], FlexTensor [58]) or aggressive pruning by evaluating incomplete programs (e.g., Halide auto-scheduler [2]), which prevents them from covering a comprehensive search space (§2).

> Ansor requires the shapes in the computational graph to be static and known in advance to do analysis, construct the search space, and perform measurements.

**Relevance to sparkles.** An argument against a fixed menu of named schedules (say
`fast`, `small`, `gpu`) as the whole optimisation story: separating structure
(sketch: which stages fuse, how loops tile) from parameters (annotation: sizes and
vector widths) gives a space that an offline tool can sample for per-device colour,
resize and filter kernels nobody hand-wrote. The static-shape requirement matches
Adams 2019's constant-size limitation, so any such search runs offline and per
output-size class, never on a cold or hostile-input path.

**Caveats.** Deep-learning operators only; static shapes and dense operators only;
leaves instruction selection to `LLVM`/`NVCC` and so cannot use special instructions
such as `VNNI` or Tensor Cores; search budgets of many measured candidates per
subgraph are incompatible with interactive use; image-specific structure (boundaries,
subsampling) is outside its operator set.

### Generating Performance Portable Code using Rewrite Rules: From High-Level Functional Expressions to High-Performance OpenCL Code (Steuwer et al. 2015)

| Field        | Value                                                                          |
| ------------ | ------------------------------------------------------------------------------ |
| Authors      | Michel Steuwer, Christian Fensch, Sam Lindley, Christophe Dubach               |
| Venue/Year   | ICFP 2015, pp. 205–217                                                         |
| DOI or arXiv | [10.1145/2784731.2784754][doi-steuwer15]                                       |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/steuwer2015-rewrite-rules.pdf` |
| Open access  | Y (preprint, [author page][pdf-steuwer15])                                     |

**Claim.** Programs are compositions of data-parallel patterns (`map`, `reduce`,
`split`, `join`, ...); semantics-preserving rewrite rules, proved correct against a
denotational semantics, lower them to `OpenCL`-specific patterns, and an automatic
search over rewrites finds device-specific code on par with expert kernels.

**Verbatim quote** (p. 1):

> Our rewrite rules define a space of possible implementations which we automatically explore to generate hardware-specific OpenCL implementations.

**Relevance to sparkles.** The pattern vocabulary is close to D ranges (`map`,
`chunks`, `joiner`, `fold`), so this paper shows how a range pipeline could be the
algorithm and rewrite rules the schedule, without a separate imperative schedule
language. In D, rewrites over expression templates are feasible at compile time but
the search is not; a fixed rewrite strategy per target is the plausible subset.

**Caveats.** Often cited as "`Lift`", but this paper never uses that name (the `Lift`
IR was named in later papers). `OpenCL`-only; evaluated on linear-algebra kernels, the
`BlackScholes` option-pricing application and a molecular-dynamics kernel, not image
pipelines.

### Achieving High-Performance the Functional Way: A Functional Pearl on Expressing High-Performance Optimizations as Rewrite Strategies (Hagedorn et al. 2020)

| Field        | Value                                                                                           |
| ------------ | ----------------------------------------------------------------------------------------------- |
| Authors      | Bastian Hagedorn, Johannes Lenfers, Thomas Kœhler, Xueying Qin, Sergei Gorlatch, Michel Steuwer |
| Venue/Year   | Proc. ACM Program. Lang. 4 (ICFP 2020), Article 92                                              |
| DOI or arXiv | [10.1145/3408974][doi-elevate]                                                                  |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/hagedorn2020-elevate.pdf`                       |
| Open access  | Y ([author page][pdf-elevate])                                                                  |

**Claim.** Pairs `RISE` (a pattern language descended from the 2015 rewrite-rule work)
with `ELEVATE`, a functional language for _strategies_ that compose rewrites.
`Halide`- and `TVM`-style schedules become user-definable library functions; the
evaluation (matrix multiplication) reaches performance competitive with `Halide` and
`TVM`.

**Verbatim quote** (p. 1):

> Unfortunately, these schedules are not written in well-defined programming languages. Instead, they are implemented as a set of ad-hoc predefined APIs that the compiler writers have exposed.

**Relevance to sparkles.** The critique applies to any D schedule API: if schedule
directives are a fixed enum, users cannot add tiling idioms. D can express schedules
as ordinary compile-time functions over a pipeline description (templates that take
and return a schedule value), which is `ELEVATE`'s point in D clothing.

**Caveats.** Research prototype embedded in `Scala`; the pearl's evaluation is matrix
multiplication, not an image pipeline; strategy composition makes failure modes (a
rewrite that silently does not apply) harder to diagnose.

### Futhark: Purely Functional GPU-Programming with Nested Parallelism and In-Place Array Updates (Henriksen et al. 2017)

| Field        | Value                                                                                |
| ------------ | ------------------------------------------------------------------------------------ |
| Authors      | Troels Henriksen, Niels G. W. Serup, Martin Elsman, Fritz Henglein, Cosmin E. Oancea |
| Venue/Year   | PLDI 2017, pp. 556–571                                                               |
| DOI or arXiv | [10.1145/3062341.3062354][doi-futhark]                                               |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/henriksen2017-futhark.pdf`           |
| Open access  | Y ([futhark-lang.org][pdf-futhark])                                                  |

**Claim.** A purely functional array language with no user schedule: the compiler
fuses producer-consumer operators, flattens nested parallelism moderately (keeping
inner loops sequential where that preserves locality), and uses uniqueness types so
in-place updates stay referentially transparent. Performance is competitive with
hand-written GPU code on 16 benchmarks.

**Verbatim quote** (p. 1):

> we introduce a simple type system for in-place updates that ensures referential transparency and supports equational reasoning.

**Relevance to sparkles.** Uniqueness types map onto D's move-only `UniqueBuffer`
and `scope`/dip1000: a stage that owns its output can update it in place while the
pipeline still reasons about it as a value. The fusion rules are a fixed alternative
to schedules when the library, not the user, picks the plan.

**Caveats.** The compiler generates `OpenCL` only in this paper (`CUDA` appears only in
hand-written comparison baselines), not `Vulkan` `SPIR-V`; no image-specific stencil
or boundary handling; schedule control is deliberately absent.

### Exocompilation for Productive Programming of Hardware Accelerators (Ikarashi et al. 2022)

| Field        | Value                                                                                    |
| ------------ | ---------------------------------------------------------------------------------------- |
| Authors      | Yuka Ikarashi, Gilbert Louis Bernstein, Alex Reinking, Hasan Genc, Jonathan Ragan-Kelley |
| Venue/Year   | PLDI 2022, pp. 703–718                                                                   |
| DOI or arXiv | [10.1145/3519939.3523446][doi-exo]                                                       |
| Local PDF    | `~/code/repos/papers/image-video/dsl-scheduling/ikarashi2022-exocompilation.pdf`         |
| Open access  | Y ([MIT CSAIL copy][pdf-exo]; CC BY 4.0 per the paper)                                   |

**Claim.** `Exo` inverts `Halide`'s design: the user writes a concrete imperative
procedure and schedules it with composable rewrites, each checked by effect analyses
for equivalence; hardware instructions and memories are user-library definitions
rather than compiler built-ins. Array sizes are dependently typed, so bounds are
checked statically.

**Verbatim quote** (p. 5):

> Exo then performs static bounds checks, guaranteeing memory safety without incurring any of the costs of dynamic bounds checks.

**Relevance to sparkles.** Two lessons for hostile-input-safe kernels: separate
_control_ values (sizes, loop bounds, known before the loop) from _data_ values, and
prove bounds once per tile rather than per access. D can approximate this by
validating a tile's extent against the view once (`in` contracts, `assert` under the
`checked` build) and then using unchecked indexing inside, with the user-defined
instruction idea matching the per-target `@target` bodies.

**Caveats.** Targets kernel libraries (GEMM, convolution) on `Gemmini` and
`AVX-512`, not whole image pipelines; embedded in `Python`; its safety and
equivalence checks discharge queries to an SMT solver.

### Access notes

- The original `PolyMage` author copy is no longer on the live lab site; the local
  file is the 2018 Wayback snapshot of the former lab URL.
- `Darkroom` and `Rigel` author copies are linked through Wayback snapshots of the
  Stanford graphics server. The `Darkroom` local file is the authors' low-resolution
  copy; the `Rigel` local file is the full-resolution version of the same paper
  (`hegarty2016-rigel-alt.pdf` beside it is the low-resolution copy).

## Thread synthesis

**Consensus.** Every system here agrees that image pipelines are memory-bound chains
of cheap stages, so the big wins come from cross-stage reorganisation (fusion, tiling,
storage folding), not from inner-loop tuning. All the image DSLs (`Halide`, `PolyMage`,
`Darkroom`, `Hipacc`) model images as functions over integer domains, with boundaries
as explicit wrappers; Elliott's continuous model is the semantic ancestor. They also
agree that schedules depend on the target: `Halide`'s 2013 cross-testing, Anderson's
register spilling and the per-device tuning of `TVM` and `Ansor` all show that one
plan does not fit all machines.

**Disagreements.** _Who decides the schedule_: the user (`Halide`, `Tiramisu`, `Exo`),
a model-driven compiler (`PolyMage`, Mullapudi 2016, `Futhark`, `Hipacc`), a learned
search (Adams 2019, Anderson 2021, `TVM`, `Ansor`) or user-written strategies over
rewrites (Steuwer, `ELEVATE`). Within learned search the split is over the space
itself: `TVM` searches inside hand-written templates, Adams 2019 prunes partial
schedules, and `Ansor` samples complete programs from an automatically built
sketch/annotation space, arguing that any fixed menu of schedules leaves performance
on the table. _What the schedule language is_: a fixed directive API (`Halide`),
rewrites with proofs (Steuwer, `Exo`), or programmable strategies (`ELEVATE`). _How
much to restrict the algorithm_: `Darkroom` forbids resampling to obtain provably
minimal buffers; `Rigel` buys it back with rates; `Halide` accepts arbitrary affine and
data-dependent accesses at the cost of only interval-based bounds.

**Open problems.** Data-dependent control across stages (entropy decoding, sparse
work) remains outside these models; GPU cost models are fragile against downstream
compilers; autoscheduling still assumes known constant sizes (Adams 2019 and `Ansor`
both state it); none of the image DSLs treat decoders, partial (streaming) inputs or
malformed sizes as part of the model.

**What a D implementation should take from this:**

- **Represent an algorithm as pure functions over an integer domain**, with borders as
  explicit wrapper stages, and keep the lazy range form as the reference oracle every
  scheduled form is tested against (Elliott, `Halide` 2012).
- **Infer bounds with axis-aligned intervals at compile time**: small enough for CTFE,
  sufficient for stencils and resampling, and the place where a hostile-size input is
  rejected before any loop runs (`Halide` 2013, `Exo`).
- **Make the schedule an ordinary compile-time value**, not a fixed directive enum,
  so tiling or vectorisation idioms are library code (`ELEVATE`, `Exo`), and split it
  into structure (fusion, tiling shape) and parameters (sizes, widths) so an offline
  tool can sample the parameters (`Ansor`).
- **Ship a deterministic heuristic default**, with estimated output size as a required
  input, and treat search or autotuning as an offline, optional, per-release tool for
  a few hot kernels (Mullapudi 2016, Adams 2019, `Ansor`, `Halide` 2013's tuning
  times).
- **Type stage rates and footprints** so line-buffer depths and inter-fiber queue
  bounds are static; this covers row-streaming decoders and chroma subsampling
  (`Darkroom`, `Rigel`).
- **Keep data layout and data movement separate from iteration order**, because
  planar/interleaved/tiled storage and `Vulkan` uploads are decided by codecs and the
  GPU path, not by the algorithm (`Tiramisu`).
- **Expose per-target micro-operations** (`@target` SIMD bodies, later compute
  shaders) as substitutable intrinsics, and measure workgroup shapes per device rather
  than hard-coding them (`TVM`, Anderson 2021, `Exo`).
- **Reuse random-program generation as a differential-testing corpus** for scheduled
  kernels against their scalar reference (Adams 2019).

## Sources

- Primary papers: the 19 entries above, each with its DOI or arXiv link and, where one
  exists, an open author copy.
- Bibliographic metadata (volumes, pages, dates) checked against Crossref and arXiv;
  USENIX proceedings pages for the two OSDI papers.

<!-- References -->

[doi-elliott]: https://doi.org/10.1007/978-1-349-91518-7_7
[pdf-elliott]: http://conal.net/papers/functional-images/fop-conal.pdf
[doi-halide12]: https://doi.org/10.1145/2185520.2185528
[pdf-halide12]: https://people.csail.mit.edu/jrk/halide12/halide12.pdf
[doi-halide13]: https://doi.org/10.1145/2491956.2462176
[pdf-halide13]: https://people.csail.mit.edu/jrk/halide-pldi13.pdf
[doi-halide18]: https://doi.org/10.1145/3150211
[pdf-halide18]: https://commit.csail.mit.edu/papers/2018/p106-ragan-kelley.pdf
[doi-polymage]: https://doi.org/10.1145/2694344.2694364
[pdf-polymage]: https://web.archive.org/web/20180413042233/http://mcl.csa.iisc.ac.in:80/polymage/asplos235-mullapudi.pdf
[doi-mullapudi16]: https://doi.org/10.1145/2897824.2925952
[pdf-mullapudi16]: https://web.archive.org/web/20170312165159/http://graphics.cs.cmu.edu/projects/halidesched/mullapudi16_halidesched.pdf
[doi-adams19]: https://doi.org/10.1145/3306346.3322967
[pdf-adams19]: https://halide-lang.org/papers/halide_autoscheduler_2019.pdf
[doi-anderson21]: https://doi.org/10.1145/3485486
[arxiv-anderson21]: https://arxiv.org/abs/2012.07145
[doi-li18]: https://doi.org/10.1145/3197517.3201383
[pdf-li18]: https://people.csail.mit.edu/tzumao/gradient_halide/gradient_halide.pdf
[doi-darkroom]: https://doi.org/10.1145/2601097.2601174
[pdf-darkroom]: https://web.archive.org/web/20150621135253/http://graphics.stanford.edu/papers/darkroom14/darkroom14-low.pdf
[doi-rigel]: https://doi.org/10.1145/2897824.2925892
[pdf-rigel]: https://web.archive.org/web/20160626120205/http://graphics.stanford.edu:80/papers/rigel/rigel-low.pdf
[doi-hipacc]: https://doi.org/10.1109/TPDS.2015.2394802
[pdf-hipacc]: https://graphics.cg.uni-saarland.de/papers/membarth-2016-tpds.pdf
[doi-tiramisu]: https://doi.org/10.1109/CGO.2019.8661197
[arxiv-tiramisu]: https://arxiv.org/abs/1804.10694
[arxiv-tvm]: https://arxiv.org/abs/1802.04799
[usenix-tvm]: https://www.usenix.org/conference/osdi18/presentation/chen
[arxiv-ansor]: https://arxiv.org/abs/2006.06762
[usenix-ansor]: https://www.usenix.org/conference/osdi20/presentation/zheng
[doi-steuwer15]: https://doi.org/10.1145/2784731.2784754
[pdf-steuwer15]: https://michel.steuwer.info/files/publications/2015/ICFP-2015.pdf
[doi-elevate]: https://doi.org/10.1145/3408974
[pdf-elevate]: https://bastianhagedorn.github.io/files/publications/2020/ICFP-2020.pdf
[doi-futhark]: https://doi.org/10.1145/3062341.3062354
[pdf-futhark]: https://futhark-lang.org/publications/pldi17.pdf
[doi-exo]: https://doi.org/10.1145/3519939.3523446
[pdf-exo]: https://cap.csail.mit.edu/sites/default/files/research-pdfs/Exocompilation%20for%20Productive%20Programming%20of%20Hardware%20Accelerators.pdf
