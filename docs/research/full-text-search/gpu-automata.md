# GPU automata — where the speedups come from, and what they cost

The accelerator question, answered as honestly as available evidence allows:
published speedups are real for the workload they measure, and that workload is
not hue's.

> **Last reviewed:** August 28, 2026.

> [!IMPORTANT]
> A **`[paper-claim]` page.** No GPU regex engine was built or run for this
> survey, and — per the [measurement protocol][measurement] — no speedup ratio is
> reported here without naming its baseline. The catalog's position is that
> thesis T4 is **unresolvable from available evidence** for this repository's
> workload, and this page says why rather than repeating abstract-level numbers.

---

## What GPU automata research actually optimises

The literature's shape is consistent across a decade of work (bitstream
execution, speculative FSM parallelisation, hybrid SA approaches, DPI-derived
engines):

- **The corpus is already resident**, or streaming steadily, so transfer is
  amortised over a large scan.
- **The pattern set is large and static** — thousands of rules, compiled once.
  This is intrusion detection's shape, and it is where multi-pattern automata
  parallelise beautifully.
- **The measurement is throughput**, in gigabytes per second, over a long run.

Every one of those is false for an interactive picker. hue's corpus changes as
the user edits, the pattern changes on every keystroke, and the metric is
**first-result latency**, not throughput — [thesis T5][index].

## The three taxes

**Transfer.** Bytes must reach the device. For a scan that would otherwise be a
`memchr` over page-cached memory, PCIe transfer is not an optimisation, it is the
new bottleneck. Papers that keep the corpus resident do not pay this; a tool
searching a working tree does, every query.

**Compilation.** Pattern-set compilation for a GPU engine is measured in
milliseconds to seconds. [Vectorscan][vectorscan]'s CPU compile is already too
slow for per-keystroke recompilation; a GPU backend does not improve that.

**The baseline.** This is the tax the literature most often avoids paying. A GPU
result measured against a naive CPU automaton is not comparable with a CPU
implementation that has a good literal prefilter — and, per [thesis T1][index],
the prefilter is where the time goes. **A speedup ratio whose denominator is
unnamed is not evidence**, which is the rule the measurement protocol states
precisely to keep this page from becoming a table of them.

## Where the idea is genuinely right

Not zero. The workload GPU automata suit — many patterns, static corpus,
throughput target — describes **batch indexing**, not interactive search. If
Sparkles ever built a content index over a static corpus (git history, per
[compressed-self-indexes][csi]), the build phase is exactly the shape these
engines serve.

## The blocker that settles it for now

Independent of any performance argument: **`sparkles:vulkan` has no compute
path.** It selects queue families by `VK_QUEUE_GRAPHICS_BIT` and neither Vulkan
library mentions compute at all — see the [baseline][baseline]. A GPU prefilter
is a compute queue, a pipeline and buffer-binding plumbing _first_, and an
experiment second.

## What this catalog concluded

**T4 is recorded as unresolved**, deliberately. Reconstructing each paper's
baseline against a prefilter-equipped CPU implementation is the work that would
resolve it, and that work is larger than the decision it would inform. The
honest position is: the taxes are real, the workload does not match, the platform
prerequisite is missing, and nothing about hue's grep source turns on the answer.

## Sources

`[paper-claim]` / `[literature]`: the GPU automata literature (bitstream and
speculative-FSM approaches, DPI-derived engines and their pangenomics
descendants). Platform facts are `[source-verified]` from the
[baseline][baseline]. Related: [gpu-retrieval](./gpu-retrieval.md),
[hardware-automata](./hardware-automata.md), and the CPU-side ceiling in
[wide-simd](./wide-simd.md).

<!-- References -->

[measurement]: ./measurement.md
[index]: ./index.md
[baseline]: ./sparkles-baseline.md
[vectorscan]: ./vectorscan.md
[csi]: ./compressed-self-indexes.md
