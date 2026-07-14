# Hardware-assisted and sampling variants (HWASan, MTE, GWP-ASan, RTSan, TySan)

The post-ASan generation: five tools that either move the memory-safety check off
the [shadow byte][shadow] and into a [pointer/memory tag][memory-tagging]
(**HWASan**, **Arm MTE**), sample it cheaply into a production fleet
(**GWP-ASan**), or repurpose the sanitizer machinery for a wholly different defect
class (**RTSan** for real-time safety, **TySan** for strict-aliasing). This page
walks each along the survey's seven concerns and reports which — if any — a D test
runner can ever reach.

| Tool         | [Locus][locus]                               | Flag / access surface                                                               | Runtime archive (compiler-rt 21.1.7)                   | Reachable from D                 | Verification                                        |
| ------------ | -------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------ | -------------------------------- | --------------------------------------------------- |
| **HWASan**   | LLVM IR pass + tagging `malloc`              | `-fsanitize=hwaddress` (+ `-fsanitize-hwaddress-experimental-aliasing` on `x86_64`) | `libclang_rt.hwasan`, `libclang_rt.hwasan_aliases`     | No — not in LDC's set            | `[hw-verified: x86_64-linux]` + `[source-verified]` |
| **Arm MTE**  | hardware tag check (no code instrumentation) | `PROT_MTE` on `mmap`/`mprotect` + `prctl` (a kernel ABI, **not** a compiler flag)   | n/a (in silicon)                                       | No — no MTE silicon in reach     | `[source-verified]` (kernel docs) + `[literature]`  |
| **GWP-ASan** | [sampling allocator][sampling-allocator]     | `-fsanitize=scudo` + `SCUDO_OPTIONS` (no `-fsanitize=gwp-asan`)                     | `libclang_rt.gwp_asan`, `libclang_rt.scudo_standalone` | **C-heap only**                  | `[hw-verified: x86_64-linux]` + `[source-verified]` |
| **RTSan**    | **LLVM IR pass**                             | `-fsanitize=realtime` on `[[clang::nonblocking]]` functions                         | `libclang_rt.rtsan`                                    | Not today (LLVM ≥ 20; LDC on 18) | `[hw-verified: x86_64-linux]` + `[source-verified]` |
| **TySan**    | **clang CodeGen** (TBAA metadata)            | `-fsanitize=type` (experimental)                                                    | `libclang_rt.tysan`                                    | **Never** — no TBAA from LDC     | `[hw-verified: x86_64-linux]` + `[source-verified]` |

> [!IMPORTANT]
> **Three of the five were exercised on this box; two could not be.** The hardware
> facts below were recorded on **Linux 6.18.26**, **AMD Ryzen 9 7940HX** (Zen 4),
> **clang 21.1.7** (`nix shell nixpkgs#llvmPackages_latest.clang`), **gcc 15.2.0**,
> against compiler-rt/clang read at [`73802c2e`][llvm-src] and the kernel at
> [`e43ffb69e043`][linux-mte] (v7.1-rc6). HWASan (aliasing mode), GWP-ASan (via
> scudo), RTSan, and TySan all ran; **plain HWASan LAM mode cannot run on this AMD
> CPU** (no Intel LAM), and **no Arm MTE silicon is in reach** — this project's only
> aarch64 box is an Apple **M4**, which has no MTE (see [Silicon
> reality](#silicon-reality-where-mte-actually-exists)). Every MTE claim is
> therefore `[source-verified]` (kernel documentation) or `[literature]`.

---

## The post-ASan generation

[ASan][asan] and [`memcheck`][valgrind] answer "is this byte addressable / defined?"
with an out-of-band [shadow map][shadow]. The tools on this page take two different
bets on _where_ the check should live:

- **Move it into a tag.** Instead of a shadow byte per granule, colour the pointer
  and the memory with a small tag and compare them on every access
  ([memory tagging][memory-tagging]). **HWASan** does this in software (an IR pass
  plus a tagging allocator); **Arm MTE** does it in hardware (the CPU checks the
  tag, no load/store instrumentation). The payoff is far smaller memory overhead
  than ASan's redzones and — for MTE — near-free spatial+temporal heap safety in
  production.
- **Sample it into production.** **GWP-ASan** keeps ASan-quality catches but pays
  for them only on a random `1/SampleRate` slice of allocations placed on guard
  pages, so a shipping binary can run it continuously (a
  [sampling allocator][sampling-allocator]).

Two more are sanitizer-shaped tools for entirely different defect classes:
**RTSan** flags real-time-safety violations (a `malloc` or lock inside a
`[[clang::nonblocking]]` function), and **TySan** flags C/C++ strict-aliasing (TBAA)
violations. They matter here for one reason each: RTSan is built as a **real LLVM IR
pass**, which makes it the one tool on this page LDC could adopt with a bounded
patch; TySan is built in **clang CodeGen** like [UBSan][ubsan], which — plus D's
absence of strict-aliasing rules — makes it a permanent N/A for D.

The field's rough timeline, for the [umbrella milestones][index]:

| When     | What                                                                                              | Tag            |
| -------- | ------------------------------------------------------------------------------------------------- | -------------- |
| 2019     | HWASan ships as Android 10's production memory-safety tool (AArch64)                              | `[literature]` |
| Nov 2023 | First MTE handset: Google Pixel 8 / Tensor G3                                                     | `[literature]` |
| 2024     | First MTE datacenter CPU: AmpereOne                                                               | `[literature]` |
| Mar 2025 | LLVM/Clang 20 introduces RTSan (`-fsanitize=realtime`) and experimental TySan (`-fsanitize=type`) | `[literature]` |
| Sep 2025 | Apple Memory Integrity Enforcement (EMTE) debuts on A19 / iPhone 17 — no M-series                 | `[literature]` |

---

## HWASan: LLVM HardwareAddressSanitizer

The software half of memory tagging — ASan's defect coverage at a fraction of the
memory overhead, by carrying the tag in the pointer's unused top bits and keeping
**1 tag byte per 16-byte granule** instead of ASan's redzones and quarantine.

### Overview

HWASan replaces ASan's "poison the neighbourhood" model with "colour every object."
The design document states the mechanism and its origin plainly
([`HardwareAssistedAddressSanitizerDesign.rst:22-27`][hwasan-design]):

> "AArch64 has Address Tagging (or top-byte-ignore, TBI), a hardware feature that
> allows software to use the 8 most significant bits of a 64-bit pointer as a tag.
> HWASAN uses Address Tagging to implement a memory safety tool, similar to
> AddressSanitizer, but with smaller memory overhead and slightly different (mostly
> better) accuracy guarantees."

`[source-verified]` The design bet is that a probabilistic tag check (a wrong access
matches the target tag by chance `1/2^8` on aarch64) buys most of ASan's coverage
with a fraction of ASan's RAM, cheaply enough to run in production — which
[Android has done since 2019][android-hwasan].

### How it works

The tag granule is **16 bytes** and the shadow is **one byte per granule**
(`kShadowScale = 4`, `kShadowAlignment = 1 << 4`,
[`hwasan_mapping.h:37-38`][llvm-src]). `[source-verified]` Where the tag lives in
the pointer is per-architecture ([`hwasan.h:40-71`][llvm-src]) `[source-verified]`:

| Target                     | Tag bits | Placement  | Notes                                                        |
| -------------------------- | -------- | ---------- | ------------------------------------------------------------ |
| aarch64 (TBI)              | 8        | bits 56–63 | the native path — top-byte-ignore is free                    |
| `x86_64` Intel **LAM**     | 6        | bit 57     | Intel-only; the `arch_prctl` probe **fails on AMD**          |
| `x86_64` **aliasing** mode | 3        | bits 39–41 | page-aliasing; **heap-only, fork-unsafe**, but runnable here |
| riscv64 pointer-masking    | 8        | bit 56     | compiled path                                                |

Anything else is `#error Architecture not supported` — HWASan is **not** an
aarch64-only tool in-tree. The heap is tagged by `malloc`, `free` retags to a
different tag, stack frames are tagged in the prologue/epilogue, and most globals
are tagged ([design doc `:128-159`][hwasan-design]). `[source-verified]`

**OS requirement — the tagged-address ABI.** On Linux/aarch64 the runtime enables
the kernel's tagged-address ABI with
`prctl(PR_SET_TAGGED_ADDR_CTRL, PR_TAGGED_ADDR_ENABLE, 0, 0, 0)`
([`hwasan_linux.cpp:187-197`][llvm-src]); the kernel side documents the control
verbatim ([`tagged-address-abi.rst:71-78`][linux-taggedaddr]):

> "`PR_SET_TAGGED_ADDR_CTRL`: enable or disable the AArch64 Tagged Address ABI for
> the calling thread. … `PR_TAGGED_ADDR_ENABLE`: enable AArch64 Tagged Address ABI.
> Default status is disabled."

`[source-verified]` On `x86_64` the runtime instead probes LAM via
`arch_prctl(ARCH_GET_MAX_TAG_BITS)` and enables it with
`arch_prctl(ARCH_ENABLE_TAGGED_ADDR, kTagBits)`
([`hwasan_linux.cpp:140-226`][llvm-src]); absent the feature it dies at startup with
`FATAL: HWAddressSanitizer requires a kernel with tagged address ABI.`
(`hwasan_linux.cpp:226`).

> [!NOTE]
> **The compiler-rt "unsubmitted patch" comment is stale.** The source comment at
> [`hwasan_linux.cpp:145-149`][llvm-src] calls the `x86_64` tag-bits `arch_prctl` API
> "a currently unsubmitted patch to the Linux kernel (as of August 2022)". At the
> pinned kernel the constants are **mainline** —
> [`arch/x86/include/uapi/asm/prctl.h:28-30`][linux-prctl]
> (`ARCH_GET_UNTAG_MASK 0x4001`, `ARCH_ENABLE_TAGGED_ADDR 0x4002`,
> `ARCH_GET_MAX_TAG_BITS 0x4003`). The blocker on _this_ box is **hardware** (AMD
> has no LAM), not the kernel API. `[source-verified]`

### The seven concerns

**Concern 1 — defect classes and blind spots.** HWASan catches the same classes as
[ASan][asan] — heap and stack out-of-bounds, heap use-after-free, stack
use-after-return, most global overflows — but by tag mismatch rather than redzone or
quarantine, so its miss profile differs: an access that lands on a differently-tagged
neighbour is caught deterministically, but a wrong access whose pointer tag _matches_
the target's by chance escapes (`1/2^8` on aarch64 TBI, a much coarser `1/2^3` in
`x86_64` aliasing mode). It has no definedness or UB coverage. Critically, the [GC
memory blind spot][gc-blind-spot] is unchanged: druntime's GC pools are `mmap`'d, never
routed through the tagging `malloc`, so a use-after-free _inside_ GC memory is as
invisible to HWASan as to ASan. `[source-verified]`

**Concern 2 — instrumentation model and recompile scope.** HWASan is an LLVM IR pass
(`HWAddressSanitizer`, present since LLVM 18) plus a tagging allocator; because it is
an IR pass, any LLVM frontend inherits it once the flag is plumbed — LDC's absence
(concern 7) is a driver gap, not an architectural one. User code must be recompiled
to tag its stack frames and check its accesses, but the tagging `malloc` is
process-wide through [allocator interception][allocator-interception], so heap
tagging covers uninstrumented callers too. `[source-verified]`

**Concern 3 — D and druntime interaction (the load-bearing one).** A conservative
GC scans the stack and heap by reading every word as a potential pointer — through
an _untagged_ address. Under HWASan that read hits tagged memory and faults. This is
**hardware-proven on this box** (Experiment 3): stripping the 3 aliasing-mode tag
bits from a `malloc`'d pointer and dereferencing it trips a tag-mismatch —

```text
tagged=0x590200000000 untagged=0x580200000000 tag=2
==2295579==ERROR: HWAddressSanitizer: tag-mismatch on address 0x580200000000 …
READ of size 4 at 0x580200000000 tags: 00/02(00) (ptr/mem) in thread T0
```

`[hw-verified: x86_64-linux]` The pointer tag is `00` (stripped), the memory tag is
`02`; the chunk is still live, so the report is a `heap-buffer-overflow`, but the
mechanism is exactly a conservative scan touching tagged memory with an untagged
pointer. **Consequence for D:** a druntime GC running under HWASan would fault on
its first tagged granule unless it untags every scanned address, or cooperates with
the runtime's public escape hatches `__hwasan_tag_memory` / `__hwasan_tag_pointer`
([`hwasan_interface.h:40-44`][llvm-src]). The _reverse_ direction is benign —
pointers _to_ GC pools stay untagged because the pools are `mmap`'d, never tagged.
[Fiber][fiber-annotation] stacks are a second open question: a fiber's stack is an
untagged `mmap`'d region while its instrumented frames are tagged, so a switch
crosses a tagging boundary druntime does not annotate. `[source-verified]` +
`[hw-verified: x86_64-linux]`

**Concern 4 — runtime control and report capture.** `HWASAN_OPTIONS` mirrors
`ASAN_OPTIONS` (shared `compiler-rt` flag parser), the default error exit code is
**99** (`cf.exitcode = 99`, `hwasan.cpp:84`), and the same
[weak-hook surface][weak-hooks] (`__hwasan_default_options`, death callbacks) applies
as for ASan. The `__hwasan_tag_memory`/`__hwasan_tag_pointer` interface doubles as the
druntime-cooperation seam of concern 3. `[source-verified]` +
`[hw-verified: x86_64-linux]` (exit 99, Experiments 1–3).

**Concern 5 — symbolization and suppressions.** A HWASan report carries the faulting
stack, alloc/free stacks, and a **tag dump** of the memory around the address (the
`Memory tags around the buggy address` grid). Symbolization is the same story as
ASan — compiler-rt needs `llvm-symbolizer`, GCC's runtime self-symbolizes via
`libbacktrace`, and neither demangles D — and [suppressions][suppression] are the
shared one-line `type:pattern` glob against mangled frames. `[hw-verified:
x86_64-linux]` (the tag dumps in Experiments 2–3).

**Concern 6 — test-runner integration semantics.** The report shape is ASan's, so
the [wrapper-and-parse][wrapper-and-parse] / [report-windowing][report-windowing]
designs port unchanged, and the distinct exit code 99 is a crude
which-sanitizer-fired signal. One sharp `x86_64` caveat: **aliasing mode is
fork-unsafe** — the [design doc][hwasan-design] warns "`x86_64` is really only safe
for applications that do not fork" (`:281-285`), so it cannot be combined with a
[process-per-test][process-per-test] runner that forks on `x86_64`. On aarch64 TBI
there is no such restriction. `[source-verified]`

**Concern 7 — platform, toolchain, and overhead.** The matrix:

- **aarch64 (the native, production-proven path).** [Android has shipped HWASan
  since Android 10 (2019)][android-hwasan]; the documented cost is roughly **~2×
  CPU, +40–50% code size, +10–35% RAM** (vs ASan's ~2× RAM), the whole point being
  RAM cheap enough for real fleets. `[literature]`
- **`x86_64` LAM.** Intel-only. On this AMD Zen 4 box, plain `-fsanitize=hwaddress`
  compiles, needs `-Wl,--no-relax` to link at `-O0 -g` (a GOTPCREL relocation vs
  hwasan globals — looks like a broken toolchain but is not), then FATALs at startup
  because the LAM `arch_prctl` probe fails (Experiment 1, exit 99). `[hw-verified:
x86_64-linux]`
- **`x86_64` aliasing mode.** Works here (Experiment 2): a heap-use-after-free is
  caught as `tag-mismatch … Cause: use-after-free`, exit 99 — but it is heap-only
  and fork-unsafe (concern 6). `[hw-verified: x86_64-linux]`
- **GCC / GDC.** GCC 15 ships `-fsanitize=hwaddress` with its own `libhwasan.so.0`;
  on this box gcc 15.2.0 compiles and links the fixture on `x86_64` _without_ `-mlam`
  and FATALs at startup exactly like clang (Experiment 8, exit 99). Because
  `-fsanitize=` is a GCC common-driver option, a working aarch64 GDC would plumb
  hwaddress **in principle** — untestable here (the `nixos-25.05` GDC is GCC 11.5,
  whose build ships no sanitizer libraries). GCC's own docs **contradict
  themselves** on targets: the `-fsanitize=address` paragraph says hwaddress is
  supported on "x86-64 (only with `-mlam=u48` or `-mlam=u57`) and AArch64" while the
  `-fsanitize=hwaddress` paragraph says "currently only available on AArch64". Tag
  the GDC cell `[literature]`/`[source-verified]`, never hw-verified.
  `[hw-verified: x86_64-linux]` + `[source-verified]`
- **LDC / DMD.** LDC's `-fsanitize=` accepts only `address, fuzzer, leak, memory,
thread` ([`cl_options_sanitizers.cpp:182-188`][ldc-src]) — no `hwaddress`; DMD has
  no sanitizer flags at all. The backend pass exists in LDC's LLVM, so HWASan is
  driver + druntime work, not a backend gap. `[source-verified]`

---

## Arm MTE: memory tagging in silicon

The hardware realization of the same idea, and the reason HWASan exists: HWASan is
the _software emulation_ of MTE, deployable today on any AArch64 (and, in aliasing
mode, `x86_64`) while the silicon rolls out. The [design doc][hwasan-design] records
the relationship directly — "SPARC ADI and Arm MTE implement a similar tool mostly
in hardware" (`:292-294`). `[source-verified]`

### How it works

MTE puts a **4-bit allocation tag per 16-byte granule in physical memory**, checked
by the CPU on every access, built on the same TBI feature HWASan borrows. The kernel
documentation states it verbatim
([`memory-tagging-extension.rst:17-22`][linux-mte]):

> "MTE is built on top of the ARMv8.0 virtual address tagging TBI (Top Byte Ignore)
> feature and allows software to access a 4-bit allocation tag for each 16-byte
> granule in the physical address space. … A logical tag is derived from bits 59-56
> of the virtual address used for the memory access."

`[source-verified]` The userspace surface is a kernel ABI, **not a compiler flag**:
mark memory with `PROT_MTE` on `mmap`/`mprotect` (anonymous and RAM-backed files
only), then select a per-thread tag-check-fault mode via
`prctl(PR_SET_TAGGED_ADDR_CTRL, …)` with `PR_MTE_TCF_{NONE,SYNC,ASYNC}` (plus an
asymmetric mode). The two checking modes trade precision against speed
([`memory-tagging-extension.rst:68-77`][linux-mte]):

> "_Synchronous_ - The kernel raises a `SIGSEGV` synchronously, with
> `.si_code = SEGV_MTESERR` and `.si_addr = <fault-address>`. The memory access is
> not performed." / "_Asynchronous_ - … `.si_code = SEGV_MTEAERR` and `.si_addr = 0`
> (the faulting address is unknown)."

`[source-verified]` The freely-downloadable [Arm MTE whitepaper][arm-whitepaper] and
arXiv 1802.09517 are the design's own citations. `[literature]`

### The seven concerns

**Concern 1 — defect classes.** Spatial and temporal heap safety by 4-bit tag
(collision probability `1/16` per access, so retagging on free and adjacency of tags
matter), checked entirely in hardware. No definedness/UB coverage — the same class
map as HWASan, minus the software allocator's freedom to choose tag granularity.
`[source-verified]`

**Concern 2 — instrumentation model.** The distinguishing feature: **loads and
stores are not instrumented at all** — the CPU checks the tag. A recompile is needed
only for _stack_ tagging; heap tagging is the allocator marking `PROT_MTE` regions
and choosing tags. This is why MTE's overhead is a fraction of HWASan's.
`[source-verified]`

**Concern 3 — D and druntime interaction.** A druntime MTE integration would mean
the GC allocator marking its pools `PROT_MTE`, tagging on allocation, and retagging
on free — a druntime allocator project, not a link-time switch — and the same
conservative-scan hazard as HWASan (concern 3 there) would apply to any untagged
scan of tagged memory. Moot without silicon. `[source-verified]`

**Concern 4 — runtime control.** **Not applicable as a runner-facing surface.** MTE
has no `*SAN_OPTIONS` environment surface; control is the kernel `prctl` ABI
(SYNC / ASYNC / ASYMM), set by whatever runtime owns the process, not by a runner's
environment. `[source-verified]`

**Concern 5 — symbolization.** Split by mode, and **partly N/A by design**. In SYNC
mode the `SIGSEGV` is precise: `si_code = SEGV_MTESERR` with `si_addr` = the faulting
address, so a handler can symbolize the access. In **ASYNC** mode `si_addr = 0` and
the faulting address is unknown _by design_ (quoted above) — a precise per-access
report is impossible, only "a tag fault happened somewhere recently." A runner that
wants attributable reports must use SYNC and pay its cost. `[source-verified]`

**Concern 6 — test-runner integration.** **Not applicable.** MTE is not a compiler
mode sparkles controls; it is a _deployment_ of otherwise-ordinary binaries on
tagging silicon. It is document-only for this survey (see the [reachability
table](#d-reachability-the-later-milestones-feed)). `[source-verified]`

**Concern 7 — platform.** See below — the concern that decides everything.

### Silicon reality: where MTE actually exists

| Platform                                       | MTE?                                  | Evidence                                                  |
| ---------------------------------------------- | ------------------------------------- | --------------------------------------------------------- |
| Google Pixel 8 / Tensor G3                     | **yes** — first handset (Nov 2023)    | Project Zero, "First handset with MTE on the market"      |
| AmpereOne                                      | **yes** — first datacenter CPU (2024) | arXiv 2511.17773 (sync checking at "single-digit" impact) |
| Arm Neoverse N2 / V2 IP                        | **yes** (IP supports MTE)             | Arm product pages `[literature]`                          |
| Android (SYNC/ASYNC/ASYMM)                     | **yes** on supported silicon          | [Android MTE docs][android-hwasan]                        |
| Apple **M4** (this project's only aarch64 box) | **NO**                                | [Apple MIE blog][apple-mie] names only A19 / iPhone 17    |

Apple's Memory Integrity Enforcement is "built right into Apple hardware and software
in all models of iPhone 17 and iPhone Air" on "the new A19 and A19 Pro chips", using
**EMTE** (Enhanced MTE, the Arm+Apple spec released 2022) — **no M-series chip is
named**. `[literature]` The direct probe (`sysctl hw.optional.arm.FEAT_MTE` on the M4
box) was blocked this run (the hardware SSH key refused non-interactive signing);
the M4-no-MTE finding therefore rests on Apple's own announcement, and is trivially
confirmable in an interactive session later.

**The bottom line for the survey: there is no MTE bed.** Every MTE claim on this page
is kernel-doc `[source-verified]` or silicon `[literature]`; HWASan (aliasing mode)
is the only tag-checking tool that actually ran on any box in reach.

---

## GWP-ASan: sampling memory safety for production

Not a test-mode tool at all — a production monitor. GWP-ASan is a drop-in `malloc`
that places a random `1/SampleRate` fraction of allocations on guard pages, catching
the sampled ones with full ASan-quality stacks at near-zero amortized cost. The
paper puts the idea memorably (arXiv [2311.09394][gwp-asan-paper], abstract):

> "These tools combine page-granular guarded allocation and low-rate sampling. In
> other words, we added an 'if' statement to a 36-year-old idea and made it work at
> scale."

`[literature]`

### How it works

A sampled allocation is placed in a page-granular pool _between guard pages_: an
overflow touches a guard page, a use-after-free touches an unmapped/protected slot,
and the `SIGSEGV` handler prints allocation and deallocation stacks
([`guarded_pool_allocator.h:141-147`][llvm-src]). The defaults are
`Enabled = true`, `MaxSimultaneousAllocations = 16`, and
`SampleRate = 5000` — "The probability (1 / SampleRate) that an allocation is
selected for GWP-ASan sampling. Default is 5000." ([`options.inc:30-33`][llvm-src]).
A `Recoverable` mode reports once and continues instead of crashing.
`[source-verified]`

There is **no `-fsanitize=gwp-asan`** flag: GWP-ASan hooks _into_ a host allocator.
On Linux the reaching flag is `-fsanitize=scudo`
([`Sanitizers.def:196`][llvm-src]); scudo compiles its GWP-ASan hooks under
`GWP_ASAN_HOOKS` ([`scudo/standalone/combined.h:33-246`][llvm-src]). The standalone
pieces ship too (`gwp_asan/optional/{backtrace_linux_libc,segv_handler_posix,options_parser}.cpp`),
so a custom allocator or druntime _could_ embed GWP-ASan directly — but no driver
flag links it by itself. `[source-verified]`

### The seven concerns

**Concern 1 — defect classes.** Heap out-of-bounds and use-after-free on _sampled_
allocations only; no stack or global coverage. Detection is **probabilistic by
design**. `[source-verified]`

**Concern 2 — instrumentation model.** None — no code is recompiled; GWP-ASan is a
`malloc`/`free` replacement (guard pages + a sampling counter). `[source-verified]`

**Concern 3 — D and druntime interaction.** The verdict that decides D-reachability:
GWP-ASan can **only ever guard C-heap allocations**. druntime's GC obtains pools via
`mmap(MAP_ANON)` (`core/internal/gc/os.d:111-117`), never through `malloc`, so a
sampled-allocator swap sees only `malloc`/`free` traffic — C libraries,
`pureMalloc`-based D, betterC — and never GC memory, for exactly the reason it is
invisible to [ASan's interceptors][gc-blind-spot]. A D integration has two shapes:
(a) `LD_PRELOAD`/scudo-link the C heap only — zero D-specific work, catches sampled
C-heap bugs in production; or (b) teach druntime's GC to place a sampled fraction of
_GC_ allocations on guard pages — a druntime allocator project, not a linking
exercise. See [d-toolchain.md][d-toolchain]. `[source-verified]`

**Concern 4 — runtime control.** `SCUDO_OPTIONS=GWP_ASAN_*` (e.g.
`GWP_ASAN_SampleRate=1` to force deterministic sampling). The non-`Recoverable`
default reports and then `SIGSEGV`s (exit **139**); `Recoverable` reports once and
continues. `[hw-verified: x86_64-linux]` (Experiment 6).

**Concern 5 — symbolization.** Reports carry allocation, deallocation, and access
stacks as raw addresses, needing an external symbolizer — the same D-demangling gap
as everywhere else. `[hw-verified: x86_64-linux]`

**Concern 6 — test-runner integration.** **Not a test-runner mode — and this is the
honest positioning.** Sampling is the opposite of a deterministic unit test: at the
default `1/5000` rate a short-lived test process catches essentially nothing.
GWP-ASan is the right tool for a _production fleet or soak run_ and the wrong tool
for a CI suite. A `--sanitize` runner would surface it, if at all, as a
production/soak mode over the C heap, never as a per-test check. `[source-verified]`

**Concern 7 — platform.** Reachable on glibc today via `-fsanitize=scudo` (verified,
Experiment 6). Production integrations per the paper: Android (scudo), Chrome, and
Apple's own variant ("several implementations … run in production in mobile,
desktop, and server"). `[hw-verified: x86_64-linux]` + `[literature]`

The hardware catch (Experiment 6): `clang -fsanitize=scudo -g uaf.c`, then
`SCUDO_OPTIONS=GWP_ASAN_SampleRate=1 ./uaf-scudo-rerun` —

```text
*** GWP-ASan detected a memory error ***
Use After Free at 0x75c14992c000 (0 bytes into a 16-byte allocation at 0x75c14992c000) …
  … was deallocated by thread … here: …
  … was allocated by thread … here: …
*** End GWP-ASan report ***
```

then `SIGSEGV` (exit 139). Without the env var the same use-after-free sails through
silently (rate `1/5000`), exit 0. `[hw-verified: x86_64-linux]`

---

## RTSan: the RealtimeSanitizer

The one tool on this page D could actually adopt. RTSan flags real-time-safety
violations — a call to a non-deterministic function inside a function the programmer
promised would not block — and, decisively, it is built as a **real LLVM IR pass**,
not a clang-CodeGen check. The doc states the model
([`RealtimeSanitizer.rst:12-16`][rtsan-doc]):

> "RTSan considers any function marked with the `[[clang::nonblocking]]` attribute to
> be a real-time function. At run-time, if RTSan detects a call to `malloc`, `free`,
> `pthread_mutex_lock`, or anything else known to have a non-deterministic execution
> time in a function marked `[[clang::nonblocking]]` it raises an error."

`[source-verified]`

### How it works: the LDC-adoptable locus

The instrumentation is a **two-part mechanism**, and the split is the whole finding:

1. **clang's only role** is mapping the frontend function-effect
   `[[clang::nonblocking]]` to the LLVM function attribute `sanitize_realtime` (and
   `sanitize_realtime_blocking` for explicitly-blocking functions),
   [`CodeGenFunction.cpp:849-856`][llvm-src].
2. **The real work is an IR pass** — `llvm/lib/Transforms/Instrumentation/RealtimeSanitizer.cpp`
   (`runSanitizeRealtime`, `:70-80`) inserts `__rtsan_realtime_enter`/`__rtsan_realtime_exit`
   at the entry/exits of `sanitize_realtime`-attributed functions and
   `__rtsan_notify_blocking_call` into blocking ones.

The IR proves the pass ran (Experiment 4, `-O0`):

```text
; Function Attrs: … sanitize_realtime … memory(none) …
define void @process() … {
  call void @__rtsan_realtime_enter()
  call void @__rtsan_realtime_exit()
  ret void
}
… @rtsan.module_ctor … calls @__rtsan_ensure_initialized()
```

`[hw-verified: x86_64-linux]` **This is what makes RTSan LDC-adoptable and UBSan/TySan
not.** Because the checks live in an IR pass keyed on a function attribute, an LDC
port needs only three things — a D-level marker (a `@ldc.attributes` UDA) that sets
`sanitize_realtime` on codegen, scheduling the pass (present in LLVM ≥ 20), and
linking `libclang_rt.rtsan`. Contrast [UBSan][ubsan] and [TySan](#tysan-the-typesanitizer),
whose checks are emitted inline by clang CodeGen with **no IR pass to borrow**, which
is exactly why they are unreachable for LDC. `[source-verified]`

**The gate.** RTSan was introduced in **LLVM/Clang 20**; LDC 1.41 bundles LLVM
**18.1.8**, and there is zero RTSan plumbing in LDC today (no `rtsan` hits in
`gen/`/`driver/`). LDC's build accepts LLVM up to > 21, so an LDC-on-LLVM-20+ build
has the pass available — the port is bounded, but blocked on the LLVM bump.
`[source-verified]`

### The seven concerns

**Concern 1 — defect classes.** Not a memory tool: calls to `malloc`, `free`,
`pthread_mutex_lock`, syscalls, and anything else known-nondeterministic, inside a
`[[clang::nonblocking]]` context (`unsafe-library-call`); plus explicitly-blocking
calls (`blocking-call`). `[source-verified]`

**Concern 2 — instrumentation model.** The IR-pass locus above — the concern that
makes RTSan matter here. `[source-verified]` + `[hw-verified: x86_64-linux]`

**Concern 3 — D and druntime interaction: `@nogc` as the compile-time cousin.** D
already has the attribute-discipline culture RTSan assumes. But `@nogc` and RTSan are
**not equivalent**: `@nogc` proves _no GC allocations_ statically, at compile time;
`[[clang::nonblocking]]` + RTSan checks _no syscalls / heap / locks at runtime_,
including through uninstrumented third-party code (the interceptors see the libc call
regardless of who compiled the caller). A D mapping could recognize a `@nonblocking`
UDA (or treat `@nogc nothrow` as a weaker proxy) and set `sanitize_realtime`; clang
additionally has a pure compile-time twin (FunctionEffectAnalysis) that D partly
covers with `@nogc`/`nothrow`. `[source-verified]`

**Concern 4 — runtime control and report capture.** `RTSAN_OPTIONS` with
`halt_on_error` (default **true**), `print_stats_on_exit`, `suppressions=<file>`, and
`suppress_equal_stacks`; the default error exit code is **43** (`cf.exitcode = 43`,
`rtsan_flags.cpp:38`). `[source-verified]` + `[hw-verified: x86_64-linux]` (exit 43,
Experiment 4).

**Concern 5 — symbolization and suppressions.** Suppression kinds are
`call-stack-contains:` and `function-name-matches:` (`rtsan_suppressions.cpp`); the
symbolization story is the shared compiler-rt one. `[source-verified]`

**Concern 6 — test-runner integration semantics.** Halt-by-default, exit 43 — a
`--sanitize` mode must handle RTSan's exit code and `halt_on_error` semantics
distinctly from ASan (which uses 1) and TySan (which continues, exit 0).

> [!WARNING]
> **The `-O1` DCE trap.** At `-O1` the fixture's `malloc(16); free(p)` pair is
> **dead-code-eliminated before the instrumentation pass runs**, and RTSan reports
> nothing (exit 0). The IR confirms it — `process()` reduces to `memory(none)`
> containing only the enter/exit pair. The `-O0` build catches the same violation
> (`unsafe-library-call`, exit 43). Any RTSan test — or a D probe — must build
> unoptimized or make the offending call escape (a global `sink`), and the docs do
> not warn about this. `[hw-verified: x86_64-linux]` (Experiment 4).

**Concern 7 — platform.** Runs with clang 21 on glibc today (Experiment 4). Blocked
from LDC by the LLVM-18-vs-≥20 gap; DMD/GDC have no path. The most tractable of the
four new-generation tools for a future D port. `[source-verified]` +
`[hw-verified: x86_64-linux]`

The live catch (Experiment 4, the escaping-`sink` fixture, `-O0`):

```text
==2038583==ERROR: RealtimeSanitizer: unsafe-library-call
Intercepted call to real-time unsafe function `malloc` in real-time context!
```

exit 43. `[hw-verified: x86_64-linux]`

---

## TySan: the TypeSanitizer

The strict-aliasing checker — and a permanent N/A for D. TySan shadows every byte
with a type descriptor and flags accesses that violate C/C++'s type-based aliasing
(TBAA) rules. It matters here only to be ruled out cleanly, twice over.

### How it works

TySan keeps **8 shadow bytes per app byte** — a pointer to a type descriptor — and
compares each access's TBAA descriptor against the shadow
([`TypeSanitizer.rst:36-38`][tysan-doc]):

> "The runtime uses 8 bytes of shadow memory, the size of the pointer to the type
> descriptor, for every byte of accessed data in the program."

`[source-verified]` It was introduced as **experimental** in LLVM/Clang 20. Its
detection is optimization-sensitive: `halt_on_error` defaults to **false**
(`tysan_flags.inc:21`), opposite of RTSan, so a violation is reported and the process
**continues, exiting 0**. `[source-verified]` + `[hw-verified: x86_64-linux]`

### The seven concerns (a page-wide N/A for D)

**Concern 1 — defect classes.** Strict-aliasing (TBAA) violations only — an access
through a pointer of a type incompatible with the object's declared type. Nothing
D's language defines as an error. `[source-verified]`

**Concern 2 — instrumentation model.** clang CodeGen emits the `!tbaa` metadata; the
TySan pass consumes it. `-O0` catch, `-O1` miss (Experiment 5): the int→float punning
fixture reports at `-O0` —

```text
==2209126==ERROR: TypeSanitizer: type-aliasing-violation on address 0x7ffe… …
WRITE of size 4 at 0x7ffe… with type float accesses an existing object of type int
… x = 1078523331
```

then continues (exit 0); at `-O1` the store is constant-folded away and nothing is
reported (`x = 1078523331`, exit 0) — despite the docs recommending "`-O1` or higher"
for performance. `[hw-verified: x86_64-linux]`

**Concern 3 — D and druntime interaction: PERMANENT N/A.** Two independent walls.
First, **LDC emits no `!tbaa` metadata at all**: the `--output-ll` of a two-field
struct with `int`/`double` loads (Experiment 7) contains **zero** TBAA nodes, and the
only "tbaa" strings in LDC's source are the generic LLVM cl-option names passed
through `-enable-tbaa`/`-struct-path-tbaa` ([`cl_options.cpp:910,1001`][ldc-src]) —
there is no emission code in `gen/`. TySan would have nothing to check for D code even
if plumbed. Second, **D has no strict-aliasing rule** — the language spec does not
adopt C's type-based aliasing model, so there is no rule to enforce. This is the same
[CodeGen-locus story][locus] that makes [UBSan unreachable][ubsan]; TySan is its
sibling. TySan for D would only ever flag violations in linked C/C++ translation units
compiled by clang with TBAA. `[source-verified]` + `[hw-verified: x86_64-linux]`

**Concerns 4–7 — not applicable.** With no `!tbaa` from LDC there is nothing to
control (concern 4), no D report to symbolize or suppress (concern 5), nothing for a
test runner to integrate (concern 6), and no D build to measure (concern 7). The
runtime exists in nixpkgs compiler-rt (`libclang_rt.tysan`), but no D frontend feeds
it. `[source-verified]`

---

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                  | Trade-off                                                                              |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| HWASan carries the tag in the pointer's top bits (TBI/LAM/alias) | ASan coverage at a fraction of the RAM — cheap enough for production       | Probabilistic misses (`1/2^8` … `1/2^3`); `x86_64` aliasing is heap-only & fork-unsafe |
| MTE checks tags in hardware, no load/store instrumentation       | Near-free spatial+temporal heap safety; only stack tagging needs recompile | Requires MTE silicon; ASYNC mode loses the faulting address (`si_addr = 0`)            |
| GWP-ASan samples `1/SampleRate` onto guard pages                 | Full stacks at near-zero amortized cost — runs in shipping binaries        | Probabilistic — useless for deterministic unit tests; C-heap only                      |
| RTSan is an IR pass keyed on a `sanitize_realtime` fn-attribute  | Any LLVM frontend can adopt it — the LDC-reachable one                     | Needs LLVM ≥ 20; `-O1` DCE can erase violations before the pass                        |
| TySan checks TBAA metadata emitted by clang CodeGen              | Reuses C/C++ type info the frontend already has                            | No non-clang frontend emits `!tbaa`; D has no strict-aliasing rules — permanent N/A    |

---

## D-reachability: the later-milestones feed

Where each tool lands for a future `--sanitize` runner, feeding
[integration-proposal.md][proposal]. The ordering follows tractability: RTSan first
(a bounded IR-pass port), GWP-ASan as a production-adjacent monitor, HWASan behind
both hardware and druntime-GC work, MTE document-only, TySan never.

| Tool         | [Locus][locus]                           | D-reachability                           | Gated on                                                                                                                        | Verdict / order                                   |
| ------------ | ---------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| **RTSan**    | LLVM IR pass                             | reachable in principle                   | LDC on LLVM ≥ 20 + a UDA→`sanitize_realtime` mapping + link `libclang_rt.rtsan`; runner needs exit-43/`halt_on_error` semantics | **first** — the most tractable new mode           |
| **GWP-ASan** | [sampling allocator][sampling-allocator] | **C-heap only**                          | scudo link or standalone hook; zero druntime work for C-heap; GC coverage = a druntime allocator project                        | production/soak monitor, **not a unit-test mode** |
| **HWASan**   | IR pass + tagging `malloc`               | reachable, but needs hardware + druntime | LDC driver plumbing + aarch64/LAM CI hardware + druntime GC untagging (the conservative-scan hazard)                            | after the memory tools — needs a hardware story   |
| **Arm MTE**  | hardware                                 | a _deployment_, not a compiler mode      | MTE silicon (none in this project's fleet; the M4 has none)                                                                     | **document-only**                                 |
| **TySan**    | clang CodeGen (TBAA)                     | **never** (N/A for D)                    | LDC emits no `!tbaa`; D has no strict-aliasing rules                                                                            | **never** — one explanatory section               |

The rationale that carries into the proposal: a per-toolchain capability
advertisement should report these honestly as
`unavailable: LDC has no -fsanitize=hwaddress/realtime/type today`, mirroring the
cpu-pmu survey's `CapabilityReport` pattern — the absence is a fact the runner
states, not a silent gap. All five runtimes _are_ realized in nixpkgs compiler-rt
21.1.7 (`libclang_rt.{hwasan,hwasan_aliases,gwp_asan,rtsan,tysan}-x86_64.a` +
scudo), so a modern compiler-rt is one `nix shell` away — the gap is entirely LDC's
driver and druntime, never the runtime library. `[hw-verified: x86_64-linux]`

---

## Adjacent tools, not re-surveyed

**KASAN and KCSAN (kernel-side).** MTE's in-kernel consumer is **KASAN's `HW_TAGS`
mode** — the kernel's own memory tagging — which "only works on arm64 CPUs that
support MTE", "always results in in-kernel TBI being enabled", and "only reports the
first found bug" before MTE tag checking is disabled
([`kasan.rst:28-30,395-399`][linux-kasan]). `[source-verified]` **KCSAN** (the Kernel
Concurrency Sanitizer) is a data-race detector by compiler instrumentation, unrelated
to memory tagging. Both are kernel tools with no bearing on a user-space D test
runner; they are noted only so the MTE lineage is complete.

**cachegrind / callgrind / massif.** These Valgrind tools are cache-simulation,
call-graph, and heap-profiling instruments — profiling, not error detection — and
belong to the [`docs/research/cpu-pmu/`][cpu-pmu] survey, which owns the
profiling story; they are cross-linked here, not re-surveyed.

---

## Sources

- LLVM `compiler-rt` / clang / llvm at [`73802c2e`][llvm-src] —
  `lib/hwasan/{hwasan.h,hwasan_mapping.h,hwasan_linux.cpp,hwasan.cpp}`,
  `include/sanitizer/hwasan_interface.h`,
  `clang/docs/HardwareAssistedAddressSanitizerDesign.rst`;
  `lib/gwp_asan/{options.inc,guarded_pool_allocator.h,optional/}`,
  `lib/scudo/standalone/combined.h`, `clang/include/clang/Basic/Sanitizers.def`;
  `lib/rtsan/{rtsan_flags.inc,rtsan_flags.cpp,rtsan_checks.inc,rtsan_suppressions.cpp}`,
  `llvm/lib/Transforms/Instrumentation/RealtimeSanitizer.cpp`,
  `clang/lib/CodeGen/CodeGenFunction.cpp`, `clang/docs/RealtimeSanitizer.rst`;
  `lib/tysan/{tysan_flags.inc,tysan.cpp}`, `clang/docs/TypeSanitizer.rst`.
- Linux at [`e43ffb69e043`][linux-mte] (v7.1-rc6) —
  `Documentation/arch/arm64/{memory-tagging-extension,tagged-address-abi}.rst`,
  `arch/x86/include/uapi/asm/prctl.h`, `Documentation/dev-tools/kasan.rst`.
- LDC at [`v1.41.0`][ldc-src] — `driver/cl_options_sanitizers.cpp:182-188` (the
  accepted `-fsanitize=` set), `driver/cl_options.cpp:910,1001` (TBAA cl-options,
  no emission); the RTSan/TBAA source greps were run against the checked-out
  `v1.42.0-91-gf4d2f831c3` (feat/wasm) tree.
- Papers & captures (retrieved 2026-07-11): the [Arm MTE whitepaper][arm-whitepaper],
  arXiv [2311.09394][gwp-asan-paper] (GWP-ASan), [1802.09517][mte-arxiv] (memory
  tagging), [2511.17773][ampereone-arxiv] (AmpereOne), the [Apple MIE blog][apple-mie],
  [Android HWASan/MTE docs][android-hwasan], Project Zero's "first handset with MTE",
  and the [LLVM 20.1.0 release notes][llvm20-notes].
- Shared vocabulary: [concepts.md][concepts] ([memory tagging][memory-tagging],
  [sampling allocator][sampling-allocator], [instrumentation locus][locus],
  [the GC memory blind spot][gc-blind-spot], [halt vs recover][halt-recover],
  [allocator interception][allocator-interception],
  [fake stack][fake-stack], [shadow memory][shadow]). Related deep-dives:
  [asan.md][asan], [ubsan.md][ubsan], [d-toolchain.md][d-toolchain],
  [comparison.md][comparison], [integration-proposal.md][proposal].

> [!NOTE]
> **No runnable CI example ships with this page.** The survey's convention is a
> CI-compiled D probe per deep-dive, but none of the five tools is reachable from a
> D compiler on this box: HWASan aliasing mode is a fork-unsafe `x86_64` C fixture that
> LDC cannot emit, GWP-ASan/RTSan/TySan are absent from LDC's `-fsanitize=` set, and
> MTE needs silicon that isn't here. The evidence is instead the in-page **Experiment
> 1–8** transcripts — clang/gcc C fixtures recorded on this box,
> `[hw-verified: x86_64-linux]`. A D probe becomes possible only after the RTSan or
> HWASan LDC port the [reachability table](#d-reachability-the-later-milestones-feed)
> scopes.

<!-- References -->

[index]: ./
[concepts]: ./concepts.md
[locus]: ./concepts.md#instrumentation-locus
[memory-tagging]: ./concepts.md#memory-tagging
[sampling-allocator]: ./concepts.md#sampling-allocator
[halt-recover]: ./concepts.md#halt-vs-recover
[interceptor]: ./concepts.md#interceptor
[allocator-interception]: ./concepts.md#allocator-interception
[gc-blind-spot]: ./concepts.md#the-gc-memory-blind-spot
[shadow]: ./concepts.md#shadow-memory
[fake-stack]: ./concepts.md#fake-stack-and-stack-use-after-return
[fiber-annotation]: ./concepts.md#fiber-annotation
[weak-hooks]: ./concepts.md#weak-hook-control-surface
[suppression]: ./concepts.md#suppression
[report-windowing]: ./concepts.md#report-windowing
[wrapper-and-parse]: ./concepts.md#wrapper-and-parse
[process-per-test]: ./concepts.md#process-per-test-isolation
[asan]: ./asan.md
[ubsan]: ./ubsan.md
[tsan]: ./tsan.md
[d-toolchain]: ./d-toolchain.md
[valgrind]: ./valgrind.md
[runner-integrations]: ./runner-integrations.md
[comparison]: ./comparison.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./integration-proposal.md
[cpu-pmu]: ../cpu-pmu/index.md
[llvm-src]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[linux-mte]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/Documentation/arch/arm64/memory-tagging-extension.rst
[linux-taggedaddr]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/Documentation/arch/arm64/tagged-address-abi.rst
[linux-prctl]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/arch/x86/include/uapi/asm/prctl.h
[linux-kasan]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/Documentation/dev-tools/kasan.rst
[ldc-src]: https://github.com/ldc-developers/ldc/tree/v1.41.0
[hwasan-design]: https://clang.llvm.org/docs/HardwareAssistedAddressSanitizerDesign.html
[rtsan-doc]: https://clang.llvm.org/docs/RealtimeSanitizer.html
[tysan-doc]: https://clang.llvm.org/docs/TypeSanitizer.html
[gwp-asan-paper]: https://arxiv.org/abs/2311.09394
[mte-arxiv]: https://arxiv.org/abs/1802.09517
[ampereone-arxiv]: https://arxiv.org/abs/2511.17773
[apple-mie]: https://security.apple.com/blog/memory-integrity-enforcement/
[android-hwasan]: https://source.android.com/docs/security/test/hwasan
[arm-whitepaper]: https://web.archive.org/web/20260228174520/https://developer.arm.com/documentation/108035/latest/
[llvm20-notes]: https://releases.llvm.org/20.1.0/tools/clang/docs/ReleaseNotes.html
