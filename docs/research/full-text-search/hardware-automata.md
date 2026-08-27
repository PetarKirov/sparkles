# Hardware automata — the AP lineage, RAP, FPGA

Purpose-built silicon for NFA simulation. A short page: the ideas are
interesting, the hardware is largely gone, and one architectural lesson survives
that is worth more than the rest.

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> A **`[literature]` page**. No hardware was available; nothing here is measured.

---

## The lineage

**Micron's Automata Processor (AP)** was the serious attempt: a DRAM-derived
architecture executing thousands of NFA states in parallel, one input symbol per
cycle, with state-transition matching done by the memory array itself. It shipped,
attracted a research community, and was discontinued.

**RAP** and related academic designs followed, generally as
processing-in-memory automata engines. **FPGA implementations** remain the live
form: an NFA compiles to a circuit, and the circuit runs at line rate.

## The architectural lesson that survives

The AP's central claim is worth stating because it is the exact inverse of the
CPU-side finding in this catalog:

> On an automata processor, adding more patterns is nearly free, because states
> execute in parallel; the cost is **loading** the automaton, not running it.

On a CPU the reverse holds. [Thesis T1][index] says the engine is rarely the
bottleneck — the prefilter and I/O are — and every CPU engine surveyed spends its
cleverness on _avoiding_ automaton execution. Purpose-built silicon makes
automaton execution free and thereby makes the whole prefilter apparatus
pointless.

That is a useful clarifier: **the prefilter tower exists because von Neumann
machines are bad at NFAs**, not because prefiltering is intrinsically the right
way to search. It is an artifact of the substrate, and knowing that is worth more
to a design discussion than any throughput number.

## Why it is out of scope

- **The hardware is not available.** The AP is discontinued; FPGAs are not in a
  developer's laptop.
- **Compilation is the cost**, and an interactive picker recompiles on every
  keystroke — the worst possible fit for an architecture whose expense is loading
  the automaton.
- **Single-pattern search does not benefit.** The win is thousands of patterns in
  parallel, and hue has one.

## What this catalog concluded

Out of scope, permanently rather than pending evidence. Retained for the
architectural observation above, which sharpens how [T1][index] should be read:
the CPU-side conclusion that prefiltering dominates is a statement about the
machine, not about search.

## Sources

`[literature]`: the Micron AP literature and its academic successors; FPGA regex
acceleration surveys. Related: [gpu-automata](./gpu-automata.md) for the same
question on commodity parallel hardware, and [Vectorscan](./vectorscan.md) for
how far SIMD gets on a CPU.

<!-- References -->

[index]: ./index.md
