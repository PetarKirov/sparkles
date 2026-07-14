# elfutils (`libelf` / `libdw` / `libdwfl`)

The survey's **code-space decoder**: it turns a raw sampled instruction pointer
into `module → symbol → source line → inline chain`, and replays DWARF Call Frame
Information to unwind a stack — and it never touches the PMU.

| Field            | Value                                                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Libraries        | `libelf` (ELF), `libdw` (DWARF), `libdwfl` (the "front-end" session layer that ties them to a live process)               |
| Role             | [Symbolization][symbolization] (address → module → symbol → line + inline expansion) and DWARF-CFI [unwinding][unwinding] |
| Public headers   | `libdwfl/libdwfl.h`, `libdw/libdw.h`                                                                                      |
| Version          | **0.194** (runtime-tested, nixpkgs) / **0.195** (source read, [`elfutils@6f8f78c`][elfutils-src])                         |
| Touches the PMU? | **No.** It is a pure decoder — one of the four the [Linux hub][linux] delegates to (concern 4)                            |
| Verification     | `[hw-verified: x86_64-linux]` — symbolized live samples (Experiment B) and a frame-pointer-less unwind (Experiment C)     |

> [!NOTE]
> This page is a decoder, so six of the survey's seven concerns are **not
> applicable** to it — and saying so is itself a finding: elfutils has no
> acquisition surface, no counter, no topology. Concern 4 is its entire reason to
> exist. The two hardware experiments referenced here were recorded on **Linux
> 6.18.26**, an **AMD Ryzen 9 7940HX** (Zen 4), **LDC 1.41**, against elfutils
> **0.194**.

---

## Overview

### What it decodes

A [`perf_event_open`][linux] sample gives you a bare number: an interrupted
instruction pointer like `0x55c5…`. That is meaningless without two things elfutils
supplies — an **address-space model** (which ELF file is mapped where, so a runtime
VA can be rebased to a file offset) and a **debug-info decoder** (ELF symbol tables
plus DWARF `.debug_line` / `.debug_info` / `.eh_frame`). `libdwfl` is the layer
that combines both: it reports the modules of a live process, then answers
`address → symbol`, `address → source line`, `address → inline chain`, and — via
DWARF CFI — `registers + stack → call frames`. `libelf` and `libdw` are the ELF
and DWARF readers underneath; `libdwfl` is what a profiler actually calls.

### Design philosophy: the non-NULL, activation-aware contract

elfutils' API is terse, C, and unforgiving about pointer contracts — which is a
recurring source of segfaults for first-time callers. Two verbatim excerpts from
the public header set the tone. The symbol lookup **requires** its output pointers
([`libdwfl/libdwfl.h:499`][elfutils-src]):

> `OFFSET will be filled in with the difference from the start of the symbol (or function entry), OFFSET cannot be NULL.  SYM is filled in with the symbol associated with the matched ADDRESS, SYM cannot be NULL.`

And the unwinder's per-frame program-counter accessor encodes the subtle
"call-site versus return-address" adjustment that every correct backtrace needs
([`libdwfl/libdwfl.h:820`][elfutils-src]):

> `/* Return *PC (program counter) for thread-specific frame STATE. Set *ISACTIVATION according to DWARF frame "activation" definition. Typically you need to subtract 1 from *PC if *ACTIVATION is false to safely find function of the caller. */`

`[source-verified]` Both are load-bearing: the first is a real segfault hit in the
first probe run; the second is why the unwind probe does `pc -= 1` for non-leaf
frames.

---

## How it works

`libdwfl` is session-oriented. A `Dwfl*` handle is opened with `dwfl_begin`, given
a `Dwfl_Callbacks` struct of four function pointers, populated with a process's
modules, and closed. The callback struct is
`{find_elf, find_debuginfo, section_address, debuginfo_path}`
([`libdwfl/libdwfl.h:72`][elfutils-src]); for the common cases elfutils ships the
standard implementations `dwfl_linux_proc_find_elf`
([`:393`][elfutils-src]) and `dwfl_standard_find_debuginfo` ([`:319`][elfutils-src])
that a caller just takes the address of. `[source-verified]`

Once modules are reported, every query is `address`-keyed and dispatched to the
owning module. The whole surface the profiler uses is a dozen functions, all in
`libdwfl.h` — the sections below walk them in the order a sample flows through
them.

> [!WARNING]
> **Version skew, recorded honestly.** The source was read at elfutils **0.195**
> (`elfutils@6f8f78c`); the probes linked against **0.194** (nixpkgs). Every API
> cited here exists in both — record 0.194 as the _tested_ version. Separately,
> `nix shell nixpkgs#elfutils` puts elfutils _binaries_ on `PATH` but **not** on
> the linker search path, so a `libs "dw" "elf"` build needs elfutils added to the
> `ci` devShell/`buildInputs`, or the two symbolizing probes cannot link.

---

## The seven concerns

The concern order is fixed across the survey. For a pure decoder, only one applies.

### Scalar counting

**Concern 1 — not applicable.** elfutils reads no counters and issues no
`perf_event_open`; grouping and [multiplexing][linux] are entirely the
[acquisition hub][linux]'s.

### Overflow sampling

**Concern 2 — not applicable to acquisition.** elfutils does not sample. It is the
_downstream_ of a sample: the [Linux ring buffer][linux-sampling] produces the IPs;
elfutils names them (concern 4).

### Precise sampling and data-source attribution

**Concern 3 — not applicable.** The [precise-sampling][precise] engines (PEBS/IBS/SPE)
and the `perf_mem_data_src` union are decoded by the kernel and
[libnuma][libnuma], not elfutils. elfutils would only ever symbolize the _code_
address of such a sample, never its data-source payload.

### Code-space decode and symbolization

**Concern 4 — the entire page.** Everything elfutils does for this survey lives
here. A sample's IP flows through four stages, then an optional stack unwind.

#### Session and the module model: `dwfl_begin` → `dwfl_linux_proc_report`

For a live process, the model is built in three calls: `dwfl_begin(&callbacks)`
([`libdwfl.h:104`][elfutils-src]), then `dwfl_linux_proc_report(dwfl, pid)`
([`:384`][elfutils-src]) — which parses `/proc/PID/maps` and reports each mapped
module — then `dwfl_report_end` ([`:190`][elfutils-src]) to finalize. Reading the
_same_ `/proc/PID/maps` is precisely how elfutils recovers the mappings that
[`PERF_RECORD_MMAP2` never emitted][linux-sampling] for pre-existing code — the two
halves of the address-space model meet at that file. `[source-verified]`

> [!NOTE]
> **Discrepancy resolved — perf uses `dwfl_report_elf`, not `dwfl_report_module`.**
> An early hypothesis was that perf's user-unwinder reports modules with
> `dwfl_report_module`; the source says otherwise. `tools/perf/util/unwind-libdw.c`
> leaves `.find_elf` unset and reports each map with `dwfl_report_elf()` instead
> (`unwind-libdw.c:66`, `:114`). Both entry points are legitimate; the probes here
> use `dwfl_linux_proc_report` (the whole-process convenience), perf reports maps
> individually. `[source-verified]`

#### Address → module → symbol → line

The resolution pipeline is four calls, each keyed on the runtime address:

1. `dwfl_addrmodule(dwfl, addr)` ([`libdwfl.h:231`][elfutils-src]) — find the
   owning `Dwfl_Module`.
2. `dwfl_module_addrinfo(mod, addr, &offset, &sym, …)` ([`:514`][elfutils-src]) —
   return the symbol **name** and fill `offset` (distance into the symbol) and a
   `GElf_Sym`. elfutils explicitly **recommends `addrinfo` over the older
   `addrsym`** ([`:520`][elfutils-src]).
3. `dwfl_module_getsrc(mod, addr)` ([`:590`][elfutils-src]) — map the address to a
   `Dwfl_Line`.
4. `dwfl_lineinfo(line, …, &lineno, …)` ([`:606`][elfutils-src]) — read the file,
   line, and column.

`[source-verified]` **Experiment B**
([`sampling-symbolize.d`](./examples/sampling-symbolize.d)) drove exactly this
sequence over ~2000 live IP samples:

```text
top self-symbols (dwfl: name — samples — file:line):
  …sumSquares…   1852   sampling-symbolize.d:137
  …mixHash…       130   sampling-symbolize.d:129
```

The hottest sampled symbol resolved to a name _and_ a source line, and a captured
`MMAP2` named the same image — closing the loop between acquisition and decode.
`[hw-verified: x86_64-linux]`

> [!WARNING]
> **The `addrinfo` non-NULL gotcha (a real segfault).** Per the header quote
> above, `dwfl_module_addrinfo`'s `offset` (arg 3) and `sym` (arg 4) arguments
> **cannot be NULL** — the prototype carries `__nonnull_attribute__ (3, 4)`. Passing
> `NULL` for either does not error; it segfaults inside `search_table`
> (`__libdwfl_addrsym`). This was hit on the first probe run on a _real_ hardware
> IP. Always pass real `GElf_Off*` and `GElf_Sym*` storage even if you only want
> the name. `[hw-verified: x86_64-linux]`

#### Inline expansion: `dwarf_getscopes`

A single address can belong to several _inlined_ frames. To recover them, drop from
`libdwfl` to `libdw`: `dwfl_module_addrdie(mod, addr, …)`
([`libdwfl.h:567`][elfutils-src]) gets the compilation-unit DIE, then
`dwarf_getscopes(cudie, addr, &scopes)` ([`libdw/libdw.h:859`][elfutils-src])
returns an **innermost-first** array of scope DIEs, walking the
`inlined_subroutine` chain. For each inline, `dwarf_decl_file` and
`dwarf_decl_line` ([`libdw.h:929`][elfutils-src]/[`:932`][elfutils-src]) give the
declaration coordinates — so a profiler can attribute one hardware IP to the full
`caller → inlined callee` source chain. `[source-verified]`

#### DWARF-CFI stack unwinding

For a [call-graph profile][unwinding] on a frame-pointer-less build, there is no
`%rbp` chain to walk — the backtrace must be replayed from DWARF Call Frame
Information. elfutils exposes a full offline unwinder:

- `dwfl_attach_state(dwfl, elf, pid, &thread_callbacks, arg)`
  ([`libdwfl.h:725`][elfutils-src]) attaches an unwind session whose
  `Dwfl_Thread_Callbacks` are `{next_thread, get_thread, memory_read,
set_initial_registers, detach, thread_detach}` ([`:661`][elfutils-src]). The
  caller's `memory_read` serves bytes (from a captured stack slab, in the offline
  case); `set_initial_registers` seeds the register file via
  `dwfl_thread_state_register_pc` ([`:783`][elfutils-src]) +
  `dwfl_thread_state_registers` ([`:775`][elfutils-src]).
- `dwfl_getthread_frames(dwfl, tid, callback, arg)` ([`:815`][elfutils-src]) drives
  the unwinder frame by frame; each callback reads the frame's program counter with
  `dwfl_frame_pc(state, &pc, &isactivation)` ([`:825`][elfutils-src]) — and applies
  the `pc -= 1` for non-activation frames the header quote mandates.
- The CFI itself comes from `dwfl_module_dwarf_cfi` / `dwfl_module_eh_cfi`
  ([`:657`][elfutils-src]/[`:658`][elfutils-src]) — `.debug_frame` and `.eh_frame`
  respectively.

`[source-verified]` **Experiment C**
([`unwind-stack-user.d`](./examples/unwind-stack-user.d)) captured
[`PERF_SAMPLE_STACK_USER` + `PERF_SAMPLE_REGS_USER`][linux-unwind] on a
`--frame-pointer=none` build and reconstructed the stack **offline**:

```text
DWARF-CFI backtrace (5 frames, frame pointers OMITTED — so this came purely from .eh_frame/.debug_frame CFI):
  #0 …level3…+0x50   #1 …level2…+0x12   #2 …level1…+0x12   #3 …workload…+0x71   #4 …run…+0x29A
```

A full five-frame in-process unwind succeeded with **no** frame pointers — driven
by `dwfl_getthread_frames`, with `memory_read` serving the captured `STACK_USER`
slab and `set_initial_registers` seeding the captured `REGS_USER` set. This is
byte-for-byte the wiring `perf` uses in `tools/perf/util/unwind-libdw.c` (the
`Dwfl_Thread_Callbacks` at `:307`, the `dwfl_attach_state` +
`dwfl_getthread_frames` drive at `:403`). The one non-portable piece is the
perf-capture → DWARF register-number permutation, which is x86-64-specific and
lives in the probe; ARM and RISC-V need their own maps (see [arm.md][arm] /
[riscv.md][riscv]). `[hw-verified: x86_64-linux]`

### Event-space and tracing

**Concern 5 — applies only to DWARF, not tracefs.** elfutils decodes DWARF debug
information; it does **not** parse a tracepoint's tracefs `format` schema or a raw
tracepoint record — that is [libtraceevent][libtraceevent]'s job. The only overlap
is conceptual (both are "schema-driven decoders").

### NUMA and topology

**Concern 6 — not applicable.** elfutils has no notion of nodes, distances, or
placement. Topology is [libnuma][libnuma].

### Event naming and encoding

**Concern 7 — not applicable.** elfutils maps _addresses_ to symbols, not _event
selectors_ to names. The `type`/`config` naming problem is
[event-naming.md][naming]'s (libpfm4 et al.).

---

## Strengths

- **One library spans the whole code-space decode**: modules, symbols, source
  lines, inline chains, and CFI unwinding — no separate unwinder to bolt on.
- **The live-process module model reads `/proc/PID/maps`**, exactly recovering the
  mappings `PERF_RECORD_MMAP2` omits — the two halves of the address-space model
  join naturally.
- **Frame-pointer-independent unwinding**: `.eh_frame`/`.debug_frame` CFI replay
  works on `-fomit-frame-pointer` builds where a `%rbp` walk cannot (Experiment C).
- **It is the reference implementation** `perf` itself links (`unwind-libdw.c`), so
  a backend that mirrors its calls inherits perf's battle-tested behavior.
- **Inline attribution** (`dwarf_getscopes`) recovers the full source chain from a
  single IP — essential for optimized builds.

## Weaknesses

- **A segfault-prone C API**: `dwfl_module_addrinfo`'s non-NULL `offset`/`sym`
  contract is enforced by an attribute, not a graceful error — a `NULL` crashes on
  a real IP (the gotcha above).
- **Debug info must be present and matching**: without DWARF line tables you get
  symbol names but no `file:line`; without a matching [build-id][build-id] you risk
  symbolizing the wrong binary (that validation is the _caller's_ discipline —
  elfutils will happily decode a stale file).
- **No PMU, no acquisition**: it is one of four decoders, useless on its own — a
  backend still needs the [hub][linux] to produce the addresses.
- **Register-map portability is the caller's problem**: the perf-capture → DWARF
  register permutation is per-ISA; elfutils gives the unwinder but not the mapping.
- **Version/link-path friction**: source vs runtime version skew, and the
  `nix shell` linker-path gap, are real integration papercuts.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                     | Trade-off                                                                             |
| ------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `libdwfl` session model over raw `libelf`/`libdw`       | One handle owns the module map, symbol tables, DWARF, and CFI for a process   | An extra layer to learn; the `Dwfl_Callbacks` struct must be populated correctly      |
| Report modules from `/proc/PID/maps`                    | Recovers the mappings `PERF_RECORD_MMAP2` never emits for pre-existing code   | Ties live symbolization to `/proc` availability; a snapshot must be captured in time  |
| `dwfl_module_addrinfo` requires non-NULL `offset`/`sym` | Lets the function return name + offset + symbol in one call, no allocation    | A `NULL` segfaults instead of erroring — an unforgiving contract for first-time users |
| Offline unwind via `Dwfl_Thread_Callbacks`              | `memory_read`/`set_initial_registers` let a _captured_ stack+regs be replayed | The caller must supply a correct per-ISA register permutation and stack slab          |
| `dwarf_getscopes` returns innermost-first inline scopes | One IP expands to its full inline chain for optimized code                    | Requires DWARF `.debug_info`; drops to a bare symbol name without it                  |

---

## Sources

- [elfutils project home][elfutils-home] and its [source tree][elfutils-src] (`libdwfl/libdwfl.h`, `libdw/libdw.h`, read at `elfutils@6f8f78c`, 0.195)
- `libdwfl/libdwfl.h` — the session model (`dwfl_begin`/`dwfl_linux_proc_report`/`dwfl_report_end`), `dwfl_addrmodule` → `dwfl_module_addrinfo` → `dwfl_module_getsrc` → `dwfl_lineinfo`, and the unwind API (`dwfl_attach_state` → `dwfl_getthread_frames` → `dwfl_frame_pc`) — all quoted/cited above
- `libdw/libdw.h` — `dwarf_getscopes`, `dwarf_decl_file`/`dwarf_decl_line` (inline expansion)
- [`tools/perf/util/unwind-libdw.c`][perf-unwind] — the reference wiring the probes mirror (`dwfl_report_elf`, not `dwfl_report_module`)
- Runnable probes: [`sampling-symbolize.d`](./examples/sampling-symbolize.d) (Experiment B) · [`unwind-stack-user.d`](./examples/unwind-stack-user.d) (Experiment C)
- The [acquisition hub][linux] this decoder serves, and the sibling decoders [libtraceevent][libtraceevent] · [libnuma][libnuma]
- Shared vocabulary: [concepts.md][concepts] ([symbolization][symbolization], [unwinding][unwinding], [build-id][build-id])

<!-- References -->

[concepts]: ./concepts.md
[symbolization]: ./concepts.md#symbolization
[unwinding]: ./concepts.md#unwinding
[build-id]: ./concepts.md#build-id
[linux]: ./linux-perf-events.md
[linux-sampling]: ./linux-perf-events.md#overflow-sampling-the-ring-buffer-perf-record-mmap2-and-ip-symbolization
[linux-unwind]: ./linux-perf-events.md#stack-unwinding-stack-user-regs-user-and-dwarf-cfi
[libtraceevent]: ./libtraceevent.md
[libnuma]: ./libnuma.md
[precise]: ./precise-sampling.md
[naming]: ./event-naming.md
[arm]: ./arm.md
[riscv]: ./riscv.md
[elfutils-home]: https://sourceware.org/elfutils/
[elfutils-src]: https://sourceware.org/git/?p=elfutils.git;a=tree
[perf-unwind]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/util/unwind-libdw.c
