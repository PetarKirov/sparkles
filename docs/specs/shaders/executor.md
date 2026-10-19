---
status: accepted
owner: sparkles:shaders
reviewed: 2026-10-20
---

# `sparkles:shaders` — The CPU executor (outline)

How a shader's GPU semantics run on the CPU. Today an entry point's pure
functions run on the host as ordinary D (`SHM1`); what has no meaning for one
invocation alone — derivatives, subgroup operations, barriers, helper
invocations — has no host behaviour at all. This page fixes the shape of the
executor that gives them one, decided in
[`D22`](./decisions.md#d22-a-scalar-reference-executor-then-spmd-on-simd). Its
requirements are coarse by design: they are refined into testable contracts
by the milestone that delivers the executor ([`PLAN.md`](./PLAN.md)), and no
implementation starts before that refinement is accepted. This page is part of
the [specification](./SPEC.md).

## Shape

**SHX1: Two executors, one semantics.** The library **must** provide a
**reference executor**, which runs the invocations of a subgroup, a quad and
a workgroup one at a time, in lock-step at every operation that exchanges
values between invocations, and **may** later provide an **SPMD executor**,
which runs them as SIMD lanes under masks. Both **must** implement the same
semantics, written down once, and the SPMD executor **must** agree with the
reference executor on every case of the conformance corpus.

_Rationale:_ A faithful emulator for tests and a fast CPU target are two
products with two contracts; SYCL removed its host device when one tried to be
both ([research](../../research/shading-languages/comparison.md#cpu-execution)).

**SHX2: What the reference executor defines.** The refinement **must**
specify, for the reference executor: the subgroup size, or sizes, it runs
and how a test selects one; which invocations are active after divergent
control flow and where they reconverge; the four lane states of an
invocation (active, inactive, helper, and predicated off) and how each
operation treats them; quads and the derivatives computed over them,
coarse and fine; barriers and workgroup memory; and the result of every
operation that a shading language leaves undefined or implementation-defined
on the GPU, so that a test can tell a behaviour the corpus pins from one it
merely observes.

_Rationale:_ HLSL's draft specification names the four lane states; the
precedents disagree on the edge cases (a shuffle from an inactive lane, a lane
that returns before a barrier), which is why they must be written down
before any executor is built.

**SHX3: Host values for resources.** The executor **must** accept host values
for every resource kind of [`SHR1`](./resources.md) — a `T` for a block, an
image for a `Sampler2D` — and **must** sample images by the filtering rules
the refinement names, within a bound the agreement oracle states.

## Not decided here

The executor's API, its performance targets, and whether the SPMD executor is
a compiler pass over LLVM IR or over MLIR's structured form are decisions of
the delivering milestones. The research gives the precedents: ISPC for
SPMD on SIMD, ILGPU's two accelerators, HIP-CPU's fibers
([catalog](../../research/shading-languages/index.md)).
