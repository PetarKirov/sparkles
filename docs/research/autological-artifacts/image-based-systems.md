# Image-based systems (Smalltalk, Lisp, Emacs, CRIU, Erlang/OTP)

Programs that carry their own state: the deepest prior art for the [Mutability axis][concepts], and the tradition in which every participant eventually collided with the same wall — a memory image and a demand-paged `mmap`-ed file want incompatible things.

| Field           | Value                                                                                                                                                                                                                                               |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Runtime state snapshots (object memory / heap / process) and one live-mutation system                                                                                                                                                               |
| Language        | Smalltalk + generated C (OpenSmalltalk/Spur) · C (Emacs `pdumper`, SBCL runtime, CRIU) · Common Lisp (SBCL `save-lisp-and-die`) · C + Erlang (ERTS, SASL `release_handler`)                                                                         |
| License         | OpenSmalltalk-VM MIT · GNU Emacs GPL-3.0-or-later · SBCL public domain + BSD-style · CRIU GPL-2.0 (library MIT) · Erlang/OTP Apache-2.0                                                                                                             |
| Repository      | [OpenSmalltalk/opensmalltalk-vm][osvm-repo] · [emacs-mirror/emacs][emacs-repo] · [sbcl/sbcl][sbcl-repo] · [checkpoint-restore/criu][criu-repo] · [erlang/otp][otp-repo]                                                                             |
| Documentation   | [squeak.org/documentation][squeak-docs] · [Emacs Lisp Reference, "Building Emacs"][internals-texi] · [SBCL manual, `save-lisp-and-die`][sbcl-sld] · [`criu(1)`][criu-man] · [Erlang Reference Manual, "Compilation and Code Loading"][otp-codeload] |
| First release   | Smalltalk-80 images 1980 · Emacs `unexec` **1982** (Spencer W. Thomas, `unexec.c` header) · SBCL 1999 (from CMUCL) · Erlang/OTP releases 1996 · CRIU 2012 · Emacs `pdumper` in Emacs 27.1 (2020)                                                    |
| Axis profile    | Multiplicity **1** / Reflexivity **2** / Closure **2** / Mutability **3**                                                                                                                                                                           |
| Index anchoring | **header** — a magic-plus-version record at offset 0 naming section extents (Squeak, `pdmp`, SBCL core); CRIU is the exception, and is **out-of-band**                                                                                              |
| Dispatch owner  | **loader** — the runtime binary, not the kernel: an image is data that a specific interpreter opens. Only SBCL's `:executable t` and Emacs's dumped `emacs` are `binfmt_elf` files in their own right                                               |

> **Revisions surveyed:** `emacs-mirror/emacs` @ [`b28750b8`][emacs-repo] (2026-08-26, `configure.ac` says 32.0.50) · `checkpoint-restore/criu` @ [`71285b3e`][criu-repo] (2026-08-23, `Makefile.versions` 4.2.1) · `erlang/otp` @ [`15f55651`][otp-repo] (2026-08-26, `OTP_VERSION` 30.0-rc0) · `sbcl/sbcl` @ [`6b0c5fe4`][sbcl-repo] (2026-08-26, `NEWS` 2.6.7-dev) · `OpenSmalltalk/opensmalltalk-vm` @ [`fb2be466`][osvm-repo] (2026-08-21). **Measured artifact:** the `emacs-30.2` portable dump from this machine's Nix store. **Platform:** POSIX throughout; CRIU is Linux-only.

> [!NOTE]
> Five systems on one page because they answer the _same_ question — "what does it mean for a program to carry its own state?" — and because their disagreements are the finding. The Lisp-machine lineage is treated here only as the maximal case and is developed in [single-level store][sls]; [SELF/selfdb][self] is the modern descendant and owns its own page. The umbrella is [Autological Artifacts][index].

---

## Overview

### What it solves

Start-up is the cheap answer and the wrong one. The expensive part of starting a large interactive system is not parsing its code but _reconstructing its object graph_: interning symbols, building method dictionaries, wiring class hierarchies, evaluating top-level forms whose results other top-level forms depend on. Doing that from source at every launch costs seconds. Doing it once and writing the resulting heap to a file costs a `read` or an `mmap`.

That is the mechanical justification, and every system here started from it. But the systems divide sharply on what they then _did_ with the artifact:

| System                                 | What is in the artifact                                                          | Written by                        | Can the running program rewrite it?                |
| -------------------------------------- | -------------------------------------------------------------------------------- | --------------------------------- | -------------------------------------------------- |
| Smalltalk-80 / Squeak / Pharo          | The **entire** object memory, including the IDE and the developer's unsaved work | the image itself, on `snapshot`   | **Yes — this is the normal way to work**           |
| Lisp images (SBCL `save-lisp-and-die`) | The whole Lisp heap, plus optionally the runtime                                 | the image itself, then it exits   | Yes, but the process must die doing it             |
| Emacs `unexec` (1982–2024)             | The running process's data segment, re-emitted as an executable                  | the running process               | **Yes — it rewrote its own `a.out`/ELF**           |
| Emacs `pdumper` (2020–)                | The Lisp heap only, as an explicit serialization plus relocation tables          | a `-batch` build step             | No — the dump is read-only input to a fixed binary |
| CRIU                                   | An arbitrary process tree's memory, fds, sockets, namespaces                     | an _external_ privileged observer | Not by the process; by `crit encode`, yes          |
| Erlang/OTP hot code loading            | Nothing on disk — the mutation is to the **live** VM's code table                | the running node, transactionally | **Yes, in production, module by module**           |

Two of those rows are the interesting ones. Erlang is the only system in this catalog that mutates a _running_ program in production, under a defined rule; and Emacs is the only one that had a fully autological artifact — a file that was simultaneously the program, its state, and its own producer — and then deliberately gave it up. The `unexec` → `pdumper` transition is the single most instructive story on this page, because it is a controlled experiment in which one variable changed (the operating system stopped tolerating a hand-relocated process image) and the artifact's autology was the thing that had to go.

### Design philosophy

The founding statement is the header comment of Emacs's `unexec.c`, and it is worth reading as written, because the whole design fits in one sentence and one date ([`src/unexelf.c`][unexelf-c], at the commit before its removal):

> ```text
>  * unexec.c - Convert a running program into an a.out file.
>  *
>  * Author:	Spencer W. Thomas
>  *		Computer Science Dept.
>  *		University of Utah
>  * Date:	Tue Mar  2 1982
>  * Modified heavily since then.
>  *
>  * Synopsis:
>  *	unexec (const char *new_name, const char *old_name);
>  *
>  * Takes a snapshot of the program and makes an a.out format file in the
>  * file named by the string argument new_name.
> ```

"Convert a running program into an a.out file" is the autological claim in six words. The counter-statement is Emacs's own, in the release notes that retired it ([`etc/NEWS.27`][news27]):

> _"Emacs now uses a 'portable dumper' instead of unexec. This improves compatibility with memory allocation on modern systems, and in particular better supports the Address Space Layout Randomization (ASLR) feature, a security technique used by most modern operating systems."_

And the manual states the same thing as a property of the _replacement_ rather than a defect of the original ([`doc/lispref/internals.texi`][internals-texi]):

> _"This method is the most preferred one, as it does not require Emacs to employ any special techniques of memory allocation, which might get in the way of various memory-layout techniques used by modern systems to enhance security and privacy."_

The Lisp world reached the identical conclusion by a different road and says so with less ceremony ([SBCL manual, `save-lisp-and-die`][sbcl-sld]):

> _"There is absolutely no binary compatibility of core images between different runtime support programs. Even runtimes built from the same sources at different times are treated as incompatible for this purpose. … This isn't because we like it this way, but just because there don't seem to be good quick fixes for either limitation and no one has been sufficiently motivated to do lengthy fixes."_

Erlang's philosophy is the odd one out, and it is stated as a language-level guarantee rather than a build trick ([`system/doc/reference_manual/code_loading.md`][otp-codeload]):

> _"The code of a module can exist in two variants in a system: current and old. … Both old and current code are valid, and can be evaluated concurrently. Fully qualified function calls always refer to current code. Old code can still be evaluated because of processes lingering in the old code."_

Two versions, no more; a third load purges the oldest and kills whatever is still executing it. That is a garbage-collection rule for _code_, and it is the only mechanism in this survey that answers the catalog's open question about running a program out of a store somebody is concurrently rewriting.

---

## How it works

### Squeak/Pharo: the whole object memory, read and swizzled

A Squeak image is a header followed by the heap. `readImageFromFileHeapSizeStartingAt` reads a 4-byte `imageFormatVersion` (`68021` for 64-bit Spur), a `headerSize`, a `dataSize`, the `oldImageBaseAddress` the heap was written at, and the `specialObjectsOop` root ([`src/spur64.stack/interp.c`][osvm-interp]). It then allocates a heap and reads the segments in:

```c
/* src/spur64.stack/interp.c — SpurSegmentManager>>readHeapFromImageFile:dataBytes: */
(segInfo->swizzle = newBase - oldBase);
bytesRead = sqImageFileRead(pointerForOop(newBase), sizeof(char), nextSegmentSize, f);
```

The destination is not a mapping of the image file. `sqAllocateMemorySegmentOfSizeAboveAllocatedSizeInto` obtains it with an **anonymous** `mmap` and retries at successively higher addresses until the kernel gives it something near where Spur wants it ([`platforms/unix/vm/sqUnixSpurMemory.c`][osvm-mem]):

```c
alloc = mmap(address, bytes, PROT_READ | PROT_WRITE /*| PROT_EXEC*/,
             MAP_FLAGS, -1, 0);
```

Then `bytesToShift = oldSpaceStart - oldImageBaseAddress` and `initializeObjectMemory(bytesToShift)` walks the heap applying `swizzleObj` to every field of every object, plus the special-objects array, the free lists, and the mark/weakling/mourn object stacks. The image is a heap dump with a base address, and loading it is a full pointer-rewrite pass. Nothing is file-backed, nothing is shared, and nothing is demand-paged.

The image is also famously _not_ one file in practice. The `.image` needs its `.changes` beside it, with the same basename, and its `.sources` in the same folder, or method sources degrade to decompiled `t1`, `t2` temporaries — the FAQ's first two entries are both about exactly that ([squeak.org/documentation][squeak-docs]). The object memory is complete; the _human-readable_ half of the artifact is out-of-band.

That second file is more interesting than the FAQ makes it sound. The `.changes` file is an **append-only log of every source-level change** made in the image — the FAQ confirms only that it must be co-located and is write-locked to a single running VM, and the append-only-log characterization here is from the ecosystem's usage rather than from a cited primary source — and it is what makes the working model survivable: a snapshot is a whole-heap write, so a crash between snapshots would otherwise lose everything since the last one, and the log is what a recovery replays. In this catalog's vocabulary the pair is a write-ahead log next to a page store, invented for the same reason SQLite has one and reached by the same route — a format whose only durable operation is "rewrite the whole thing" needs a journal beside it. It is also the reason the Smalltalk image is not, strictly, an autological artifact of the [redbean][zip] kind: the file that is the program is not the file that records what changed in it.

### Emacs: `unexec`, and why it had to go

`unexec` re-emitted the running process. The ELF variant read the original executable, enlarged `.data` to cover everything the process had allocated since start-up, rewrote the section and program headers, and wrote a new executable — explicitly avoiding `mmap` on the way (`"We do not use mmap because that fails with NFS. Instead we read the whole file, modify it, and write it out."`, [`src/unexelf.c`][unexelf-c]). Emacs's own allocator had to cooperate: `sheap.c` provided a static heap so that early allocations landed somewhere `unexec` could describe. The whole arrangement depends on three assumptions that stopped holding — that the process's data lives at a fixed, known address; that `malloc`'s internal state is safe to freeze and thaw; and that the loader will place the resulting file where the dumped pointers expect. ASLR breaks the first, modern `malloc` implementations the second, and PIE the third.

The replacement inverts the direction. `pdumper` does not dump the process; it **serializes the Lisp heap** and emits a relocation program for reconstructing it anywhere. The format's own comment states the contract ([`src/pdumper.c`][pdumper-c]):

> _"An Emacs dump file contains the contents of the Lisp heap. On startup, Emacs can start faster by mapping a dump file into memory and using the objects contained inside it instead of performing initialization from scratch. The dump file can be loaded at arbitrary locations in memory, so it includes a table of relocations that let Emacs adjust the pointers embedded in the dump file to account for the location where it was actually loaded."_

The dump is cut into three regions named in the header — `DS_HOT`, `DS_DISCARDABLE`, `DS_COLD` — and `pdumper_load` maps them contiguously from the same fd:

```c
/* src/pdumper.c — pdumper_load() */
sections[DS_COLD].spec = (struct dump_memory_map_spec)
  { .fd = dump_fd,
    .size = dump_size - header->cold_start,
    .offset = header->cold_start,
    .protection = DUMP_MEMORY_ACCESS_READWRITE, };
if (!dump_mmap_contiguous (sections, countof (sections)))
  goto out;
```

`DUMP_MEMORY_ACCESS_READWRITE` resolves to `MAP_PRIVATE` in `dump_map_file_posix`, so the dump _is_ file-backed and demand-paged — until a relocation writes to a page, which copies it. Two relocation kinds run: `dump_relocs` fix pointers **inside** the dump for the load address, and `emacs_relocs` write **into the Emacs binary's own data segment**, in six flavours (`RELOC_EMACS_COPY_FROM_DUMP`, `RELOC_EMACS_IMMEDIATE`, `RELOC_EMACS_DUMP_PTR_RAW`, …). The discardable region is `MADV_DONTNEED`-ed once its contents have been copied into Emacs.

Two consequences make Emacs the clearest case in the catalog. First, the artifact **split in two**: an ordinary PIE ELF executable and a separate `.pdmp` data file, located at run time via `--dump-file` or a default path. Second, the two halves are welded by a hash. `make-fingerprint` computes a digest of the freshly linked `temacs` and patches it into the binary in place ([`lib-src/make-fingerprint.c`][fingerprint-c]); `pdumper_load` compares it against the dump's copy and refuses on mismatch. On this machine the fingerprint is also the dump's _filename_: `emacs-31c0351ac3ea39ff514f4b80c1a7bd95f4ab79ca561e6b09bc2e01611c300331.pdmp`. That is content addressing arrived at independently, for the same reason [build-ids][provenance] exist.

Dumping is now a build step, not a user gesture: `Fdump_emacs_portable` refuses outright in an interactive session ([`src/pdumper.c`][pdumper-c]):

```c
if (! noninteractive)
  error ("Dumping Emacs currently works only in batch mode.  "
         "If you'd like it to work interactively, please consider "
         "contributing a patch to Emacs.");
```

The old regime's fingerprints are still visible in the new code. `Fdump_emacs_portable` binds `Vpurify_flag` to `nil` for the duration of the dump — `purify` being the pre-`pdumper` mechanism that copied objects into a separate "pure" space so `unexec` could mark them read-only — and, under `REL_ALLOC`, calls `r_alloc_inhibit_buffer_relocation (1)` around the whole operation, because Emacs's own relocating buffer allocator would otherwise move data out from under the serializer. Both are load-bearing only because Emacs still contains allocators built for the world in which the process image was the artifact.

`unexec` was deprecated in Emacs 27.1 and deleted in Emacs 31: commit [`7ce34a3b`][unexec-removal] (2024-12-12, Pip Cet) removed `sheap.c`, `unexec.h` and the eight per-platform `unex*.c` files, 4,666 lines in total; `etc/NEWS.31` records it as _"The traditional unexec dumper, deprecated since Emacs 27, has been removed."_ ([`etc/NEWS.31`][news31]).

### SBCL: a core file, `mmap`-ed, with a read-only space

`save-lisp-and-die` writes a core: _"enough information to restart a Lisp process later in the same state … Only global state is preserved: the stack is unwound in the process."_ ([SBCL manual][sbcl-sld]). `coreparse.c` walks a directory of spaces (`READ_ONLY`, `STATIC`, `PERMGEN`, `IMMOBILE_FIXEDOBJ`, `IMMOBILE_TEXT`, `DYNAMIC`) and maps each one, and the mapping flags are the whole story ([`src/runtime/os-common.c`][sbcl-oscommon]):

```c
/* src/runtime/os-common.c — load_core_bytes() */
int protection = 0, sharing = MAP_PRIVATE;
protection = (addr ? (is_readonly_space ? OS_VM_PROT_READ : OS_VM_PROT_ALL)
              : OS_VM_PROT_READ | OS_VM_PROT_WRITE);
if (is_readonly_space) sharing = MAP_SHARED;
```

Read-only space is `MAP_SHARED | PROT_READ` straight off the core file: **file-backed, demand-paged, and shared between every process running that core.** Everything else is `MAP_PRIVATE`. And what goes into read-only space is exactly the `:purify` argument's job — _"If true (the default), then some objects in the restarted core will be memory-mapped as read-only. Among those objects are numeric vectors that were determined to be compile-time constants, and any immutable values according to the language specification such as symbol names."_ `:purify` is not a garbage-collection tuning knob; it is a **page-sharing** knob, and it is on by default.

ASLR does to SBCL what it did to Emacs. When the runtime is built with `LISP_FEATURE_ASLR`, `coreparse.c` throws away the core's preferred address before mapping and lets the OS choose ([`src/runtime/coreparse.c`][sbcl-coreparse]):

```c
/* Try to map at address requested by the core file unless ASLR. */
#ifdef LISP_FEATURE_ASLR
    addr = 0;
#endif
```

and `relocate_heap` then adjusts every affected word, including each entry of the linkage space. Same problem, same answer, arrived at independently of Emacs.

### CRIU: the image that refuses to contain the program

CRIU checkpoints an arbitrary process tree from outside. It parses `/proc/$pid/smaps` and `/proc/$pid/map_files/`, injects **parasite code** into the target so that the target's own address space can be read from inside it, and moves pages out with `vmsplice(SPLICE_F_GIFT)` into a pipe that the dumper `splice`s into `pages-$id.img` ([`memory-dumping-and-restoring.md`][criu-memdump]). The metadata is a directory of Protocol Buffers images — `mm-$id.img` holds an `mm_entry` with the auxv and a repeated `vma_entry`, and `pagemap-$id.img` holds the `pagemap_entry` records that say where each range's bytes are.

The decision that matters for this catalog is what CRIU refuses to copy:

> _"Unchanged File Pages: Read-only, file-backed pages (like library code) that have not been modified are not dumped. CRIU simply records the file and offset to re-map them during restoration."_ — [`memory-dumping-and-restoring.md`][criu-memdump]

Restore re-`mmap`s those VMAs **from the original files on the destination host**, which is why a restored process keeps file-backed, shared, demand-paged text. It is also why the artifact is not closed over anything: it names `libc.so.6` and trusts the destination to have the same one. The guard is a build-id check ([`validate-files-on-restore.md`][criu-validate], `--file-validation buildid`, the default per [`criu(1)`][criu-man]): at most `BUILD_ID_MAP_SIZE = 1048576` bytes of each ELF are mapped to extract `NT_GNU_BUILD_ID` ([`criu/files-reg.c`][criu-filesreg]), and a mismatch aborts the restore. Emacs's fingerprint, SBCL's runtime-incompatibility rule, and CRIU's build-id are three independent inventions of the same constraint.

Restoring also reproduces, at the level of a whole process, the manoeuvre SELF's `native.c` performs for one program: the restorer must vacate its own address space while still executing. CRIU's answer is a freestanding PIE blob relocated into a hole that neither CRIU's temporary mappings nor the target's final layout occupies — `restorer_get_vma_hint` in [`criu/cr-restore.c`][criu-restore] walks the two VMA lists in lockstep to find it — after which the blob unmaps CRIU, rebuilds the target's mappings, and finishes with `sigreturn` off a hand-built signal frame ([`restorer-context.md`][criu-restorer], [`stages-of-restoring.md`][criu-stages]).

### Erlang/OTP: mutate the running program, under a rule

ERTS never writes an image. Its equivalent of "the artifact carries its state" is that the _node_ carries it, and code is replaced underneath it. The mechanism is a small MVCC scheme over the code tables ([`erts/emulator/beam/code_ix.h`][code-ix]):

> _"The basic idea is to maintain several 'logical copies' of the code. These copies are identified by a global 'code index', an integer of 0, 1 or 2. … The current 'active' code index is used to access the current running code. The 'staging' code index is used by the process that performs a code change operation. When a code change operation completes successfully, the staging code index becomes the new active code index. The third code index is not explicitly used. It can be thought of as the 'previous active' or the 'next staging' index."_

Three indices, one active, one staging, one quarantined until every scheduler has been observed to have moved past it — this is a commit protocol, and its purpose is stated as _"allowing executing Erlang processes to access the code without any locks or other expensive memory barriers."_ Above it sits the two-version rule quoted earlier, and above _that_ sits `release_handler`, which drives an upgrade from a `relup` file generated from per-application `.appup` files. A stateful upgrade is a defined dance ([`release_handling.md`][otp-relhandling]):

> _"Suspend the processes using the module … Ask them to transform the internal state format and switch to the new version of the module. Remove the old version. Resume the processes. This is called synchronized code replacement"_

executed via `sys:suspend/1,2`, `sys:change_code/4,5` and `sys:resume/1,2`, with the affected processes discovered by walking each application's supervision tree and reading the `Modules` field of every child specification. The documentation is candid that this leaks: _"During release handling, non-affected processes continue normal execution. This can lead to time-outs or other problems. For example, new processes created in the time window between suspending processes using a certain module, and loading a new version of this module, can execute old code."_ A transaction with a defined isolation level, and the level is not serializable.

The part of that machinery which speaks directly to this catalog is what happens to the _data_ the purged code owned. Compiled BEAM modules carry **literal areas** — constant terms shared by reference with every process that touched them — so purging a module's code cannot simply free them: an arbitrary number of process heaps may hold pointers in. ERTS's answer is a dedicated `erts_literal_area_collector` process running a protocol that reads like a distributed two-phase commit ([`erts/emulator/beam/beam_bif_load.c`][beam-bif-load]):

> _"The literal area collector process sends copy-literals requests to all processes in the system. Processes inspects their heap for literals in the area, if such are found do a literal-gc to make copies on the heap of all those literals, and then send replies to the literal area collector process. … When all processes has responded, the literal area collector process calls `erts_internal:release_literal_area_switch()` again in order to switch to the next area."_

Between phases the collector suspends itself waiting on thread progress, twice, so that both the publication of the area and the subsequent change of the blocking counters are guaranteed visible to every scheduler; terminating processes bump a counter to hold the release open until they are done. This is a **mark-and-sweep over a store that is being executed from, with no stop-the-world**, and the catalog asks for exactly that in [its closure cluster's open question][open]. It exists, it ships, and it is roughly four hundred lines of C plus one system process.

---

## Format identity and multiplicity

**Multiplicity = 1, and deliberately so.** Every artifact here is one format with one parse. A Squeak image is identified by a 4-byte format version at offset 0 (`68021`, `6521`, and their byte-swapped forms — the reader tries both and sets `swapBytes`); an Emacs dump begins with the 16-byte literal `DUMPEDGNUEMACS\0\0`; an SBCL core begins with a core magic and a directory of spaces; a CRIU image file begins with a magic and holds length-prefixed protobufs. None of them is polyglot, none is prefix- or suffix-tolerant in [the ZIP sense][zip], and none wants to be: a heap image has to be read in full by exactly one program that already knows its layout.

The two places multiplicity does appear are instructive because they appear _outside_ the image:

- **SBCL `:executable t`** concatenates the runtime and the core into one file, and `:executable :elf-object` (marked experimental in the manual) wraps a core in a `.o` for further linking. This is a chimera in the [concepts][concepts] sense — runtime in front, core behind, neither reinterpreting the other's bytes — and it is the only route by which any artifact on this page becomes a `binfmt_elf` file the kernel will execute directly.
- **Erlang's `escript`** is the ZIP story exactly. An `escript` may be source, a `.beam` file, or _"an entire Erlang archive"_, and the header is optional: _"you can make an archive file executable by prepending the file with the lines starting with `#!` and `%%!`"_ ([`erts/doc/references/escript_cmd.md`][escript-doc]). `escript factorial.zip 5` runs a bare ZIP with no header at all. `escript:extract/2` hands back the archive as a binary you can write out and open with `zip:foldl/4` ([`lib/stdlib/src/escript.erl`][escript-erl]). That is prefix-tolerance exploited precisely as [ZIP parasitism][zip] predicts — and note where it sits: in the _distribution_ format, never in the _image_.

Emacs is the case where multiplicity was lost as a direct result of the ASLR retreat. An `unexec`-ed Emacs was one file that was simultaneously a valid ELF executable, the Lisp heap, and the output of its own execution. A `pdumper` Emacs is two files, one of which (`emacs`) is a perfectly ordinary PIE with nothing autological about it, and the other of which (`.pdmp`) is inert data keyed to that binary by a hash. **The catalog's headline property was traded away for compatibility with the platform's memory model**, and that trade is the page's central evidence.

---

## Index anchoring and random access

**Header-anchored, and then nothing.** These formats put a locator at offset 0 and are otherwise designed to be consumed whole. There is no partial read, because a heap has no meaningful proper subset: a live object graph is closed under reference, so reading "just the part you need" is undecidable without first reading the pointers, which are the thing you were trying not to read.

The decoded header of a real dump makes the shape concrete. Parsing `emacs-31c0351a….pdmp` (Emacs 30.2, 17,719,896 bytes) against `struct dump_header` gives:

| Field                           |                     Value | Meaning                                          |
| ------------------------------- | ------------------------: | ------------------------------------------------ |
| `magic`                         |          `DUMPEDGNUEMACS` | 14 bytes plus two NULs                           |
| `fingerprint`                   |           `31c0351a…0331` | 32 bytes; also the file's own name               |
| `dump_relocs[EARLY_RELOCS]`     | @14,216,384 × **591,692** | pointer fixups inside the dump                   |
| `dump_relocs[LATE_RELOCS]`      |          @16,583,152 × 92 | after the load hooks run                         |
| `dump_relocs[VERY_LATE_RELOCS]` |       @16,583,520 × 6,056 | last, with the allocator available               |
| `object_starts`                 |     @16,607,744 × 264,458 | one entry per dumped object, for conservative GC |
| `emacs_relocs`                  |       @17,665,576 × 3,395 | writes into the Emacs binary's data segment      |
| `discardable_start`             |                10,150,088 | end of the hot region                            |
| `cold_start`                    |                10,420,224 | start of the never-relocated region              |

The parse checks out arithmetically, which is worth stating because it is what makes the numbers usable: the relocation tables are 4 bytes per entry (`(16,583,152 − 14,216,384) / 591,692 = 4.00`), `emacs_reloc` is 16, and `17,665,576 + 3,395 × 16 = 17,719,896` — exactly the file size. So the layout is:

- **hot**, 0 – 10,150,088 (9.68 MiB) — mapped `MAP_PRIVATE`, and the target of 591,692 relocations;
- **discardable**, 10,150,088 – 10,420,224 (264 KiB) — copied into Emacs, then `MADV_DONTNEED`;
- **cold**, 10,420,224 – 17,719,896 (6.96 MiB), of which 3.34 MiB is the relocation and object-start tables themselves (they live in the cold section by construction) and 3.62 MiB is cold Lisp data.

Random access is therefore possible in exactly one direction and nobody uses it: you could `mmap` the cold region and read a string without touching the hot region, but no tool does, because there is no index from _name_ to _offset_ — only from _offset_ to _relocation_. Compare [SELF][self], where the identical data is a b-tree and `SELECT soname FROM ldd` touches three pages of a 96 MiB file. A heap image is the purest illustration of [thesis 1][concepts]: it has an index (`object_starts`, sorted, binary-searched — the comment says so: _"We need an explicit end indicator (as opposed to a special sentinel) so we can efficiently binary search over the relocation entries"_), a string region, and a foreign-key discipline, all hand-rolled, none queryable.

**CRIU is the exception and proves the rule.** Its state is a _directory_, not a file: `inventory.img`, `pstree.img`, `core-$pid.img`, `mm-$pid.img`, `pagemap-$pid.img`, `pages-$id.img`, one per concern. That is out-of-band indexing taken to its conclusion, and it buys exactly what out-of-band indexing always buys — you can read one part without the others. `crit x <dir> mems` explores memory maps without decoding sockets; `pagemap_blocks.total_payload_size` exists specifically so a reader can _"advance the read offset past a whole entry"_ in O(1) instead of summing per-block sizes ([`images/pagemap.proto`][pagemap-proto]). It also buys the standard failure mode: the image set is only meaningful next to the filesystem it was taken against.

---

## Reflexivity and query surface

**Reflexivity = 2**, and the two sub-questions of [the axis][concepts] come apart harder here than anywhere else in the catalog.

**Self-interrogation is maximal.** A Smalltalk image is the limiting case: the compiler, the debugger, the inspector and the class library are objects _in_ the heap being inspected, so `thisContext`, `Object>>inspect` and the browser are not tools pointed at the program, they are the program pointing at itself. Nothing in this survey — nothing in the catalog — scores higher on the "can it interrogate itself while running" half. Emacs is nearly as strong for the same reason (`C-h f`, `describe-variable`, and the byte-compiler are Lisp objects in the dumped heap), and SBCL likewise via `describe`, `sb-introspect` and the debugger. `pdumper` even exposes its own load as data: `(pdumper-stats)` returns an alist of `dumped-with-pdumper`, `load-time` and `dump-file-name` ([`doc/lispref/internals.texi`][internals-texi]).

**Interrogation of the artifact at rest is close to absent**, and this is the axis's other half failing. There is no `readelf` for a `.pdmp`, no `sqlite3` for a `.image`, no general question-asking surface over a core file. The only ways to ask a Squeak image a question are to _run_ it or to reimplement Spur's object format. The asymmetry is total: these are the most self-aware artifacts in the catalog while executing and the most opaque while sitting on disk. That is the precise gap [sqlelf][sqlelf] and [SELF][self] set out to close for ELF, and it is why a heap image never developed the tooling ecosystem a self-describing format gets for free.

Three partial exceptions are worth naming:

- **`crit`** is a real query surface for a CRIU image, and the only one on this page. `crit decode` converts a binary image to JSON, `crit show` pretty-prints it, `crit info` summarizes, and `crit x <dir> {ps,fds,mems}` answers the three questions people actually ask ([`Documentation/crit.txt`][crit-doc]). It works because CRIU's images are protobufs with a published schema — that is [thesis 2][concepts] doing its job. Crucially `crit` also has **`encode`**: JSON back to binary, so a checkpoint can be _edited_ between dump and restore.
- **Erlang's runtime is queryable by design**: `code:all_loaded/0`, `code:which/1`, `erlang:check_process_code/2`, `sys:get_state/1`. The release handler's own upgrade planning is a query — it discovers which processes use a module by walking supervision trees and reading child specifications.
- **`pdumper`'s `object_starts` table** is a genuine on-disk index of object identity, added not for tooling but because conservative GC needs `pdumper_object_type` to work on a pointer into the dump. An index that exists only to serve the collector, and that no user-facing tool reads, is a compact statement of where these formats put their effort.

---

## Closure, dedup, and size model

**Closure = 2** — designed-in, but bounded, and each system draws the boundary at a different place.

A Smalltalk image is _maximally_ closed over everything in Smalltalk and _not at all_ closed over the VM: the image is unrunnable without a matching interpreter, and the interpreter is a separately distributed native binary per platform. That split is the entire portability strategy — one image, N VMs — and it is [thesis 5][concepts] in a system that predates the thesis by three decades. It is also incomplete, since the `.changes` and `.sources` files must travel alongside for the sources to be readable at all.

Emacs, post-`pdumper`, is closed over its Lisp but split across two files welded by a hash. SBCL with `:executable t` is the only configuration here that produces a genuinely single-file closed artifact — runtime plus heap — and it pays for it in size. CRIU is the anti-closure case: it deliberately does _not_ carry the file-backed pages it references, and validates rather than contains.

### Numbers

Measured on this machine, from the Nix store (`emacs-30.2`):

| Artifact                           |      Bytes | Note                                              |
| ---------------------------------- | ---------: | ------------------------------------------------- |
| `bin/emacs-30.2` (PIE ELF)         | 10,186,640 | ordinary executable, nothing dumped into it       |
| `emacs-31c0351a….pdmp`             | 17,719,896 | the Lisp heap plus relocation tables              |
| — of which relocation/index tables |  3,503,512 | 19.8% of the dump is metadata _about_ the dump    |
| — of which hot (relocated) region  | 10,150,088 | 57.3%, private-dirty after load                   |
| — of which cold (mappable) data    |  3,796,160 | 21.4%, the only part that can genuinely be shared |
| combined artifact                  | 27,906,536 | two files, one hash binding them                  |

Two readings follow. First, the metadata tax is large and structural: nearly a fifth of an Emacs dump is relocation bookkeeping, which exists solely because the image may land at an arbitrary address. `pdumper.c`'s own TODO list names the escape — _"Preferred base address for relocation-free non-PIC startup"_ — and it is the one item on that list that ASLR forbids. Second, the shareable fraction is small. Only the cold region is untouched by relocation, and it is 21% of the dump.

Deduplication is where CRIU is far ahead of everyone, because it is the only system that expects to write the same image repeatedly. `pagemap_entry.in_parent` marks a page as identical to the parent snapshot's, detected via the kernel's soft-dirty bit during `pre-dump`, so iterative checkpoints store only deltas; `--auto-dedup` goes further and `fallocate(FALLOC_FL_PUNCH_HOLE)`s the image files _as it reads them during restore_, freeing disk blocks the instant their contents are in RAM ([`memory-images-deduplication.md`][criu-dedup]). Compare [content-addressed chunking][chunking], which solves the same problem with hashes instead of with a chain of parent images and a kernel bit; CRIU's version is cheaper and strictly less general, since the chain only dedups against _its own_ ancestry.

Erlang's size model is the outlier because there is no image: an OTP release is a directory of `.beam` files and applications, and the live cost is bounded by the two-version rule — at most two copies of any module's code, plus its literal areas, at any instant. That is a size guarantee expressed as a _concurrency_ rule, which no other system here attempts.

---

## Mutability, dispatch, and trust

**Mutability = 3**, and this page is where the axis was invented. But the systems split three ways on _who_ does the mutating, and the split predicts everything else about them.

**The program rewrites its own file (Smalltalk, `unexec`).** Squeak's `snapshot` writes the entire object memory back over the `.image`, including the state of every open window and the developer's half-finished edit; that is the normal working mode, not a recovery feature. `unexec` did the same thing to an ELF executable. Both are the full autological property, and both are the configurations that could not survive contact with a modern memory model.

**A build step writes it; the program only reads (`pdumper`, `save-lisp-and-die`).** Emacs's dump is generated in `-batch` and is thereafter immutable input. SBCL's core is written by a process that must then die (_"It corrupts the current Lisp image enough that the current process needs to be killed afterwards"_ — the manual's own words, and the recommended workaround is to fork a child to do the saving). The self-mutation is gone; what remains is a fast start.

**Nobody writes a file at all (Erlang).** The mutation is to live memory, transactionally, with the three-index commit protocol and the two-version rule doing the work a filesystem would otherwise do.

### `mmap` is the load-bearing constraint, five times over

This section is the page's contribution to [thesis 4][concepts], and the evidence is unusually clean because five independent teams hit the same wall and their fixes converge:

| System          | Where the image lands                                                  | Shared between processes?                               | Demand-paged? |
| --------------- | ---------------------------------------------------------------------- | ------------------------------------------------------- | ------------- |
| Squeak/Spur     | anonymous `mmap`, then `read` into it, then swizzle every pointer      | **No**                                                  | **No**        |
| Emacs `unexec`  | the ELF's own `.data`, mapped by `binfmt_elf`                          | Until first write — then COW, and it wrote a lot        | Yes           |
| Emacs `pdumper` | `MAP_PRIVATE` file-backed, three regions                               | Cold region yes; hot region no                          | Yes           |
| SBCL            | `MAP_SHARED` for read-only space, `MAP_PRIVATE` elsewhere              | **Read-only space yes** — that is what `:purify` buys   | Yes           |
| CRIU            | original files re-`mmap`ed; anonymous VMAs refilled from `pages-*.img` | **Yes for file-backed** — the point of not dumping them | Yes           |
| [SELF][self]    | `MAP_PRIVATE\|MAP_ANONYMOUS`, then `memcpy` out of b-tree pages        | **No**                                                  | **No**        |

The convergence is the finding: **every system that recovered any sharing did it by carving out a region that is never relocated and mapping that region directly off the file.** Emacs calls it the cold section and describes it in exactly those terms ([`src/pdumper.c`][pdumper-c]):

> _"Start of the region that does not require relocations and that we expect never to be modified. This region can be memory-mapped directly from the backing dump file with the reasonable expectation of taking few copy-on-write faults."_

SBCL calls it read-only space and gates it on `:purify`. CRIU calls it "unchanged file pages" and simply declines to dump them. Three names for one idea, invented separately, all of them a _partition of the image into a relocated part and a mappable part_ — and in every case the mappable part is the minority. Emacs's is 21% of the dump. Squeak, which never partitioned, gets zero.

The numbers sharpen the point. The `emacs-30.2` hot region is 10,150,088 bytes — 2,478 pages of 4 KiB — and carries 591,692 early relocations, roughly **239 relocations per page**. There is no plausible distribution under which a meaningful number of those pages escape being written, so essentially the whole hot region is private-dirty in every Emacs process on the machine. Ten megabytes per process, unshared, is the price of ASLR compatibility, and it is invisible in start-up benchmarks because it shows up as RSS rather than latency — the same measurement trap [the SELF page][self] identifies and [the measurement page][measurement] owns.

> [!WARNING]
> The 239-relocations-per-page figure is a **density**, derived from the decoded header of one dump, not a measurement of dirtied pages. Relocation entries are sorted by dump offset and could in principle cluster; nothing in the sources states their distribution, and the honest statement is "the mean is 239 per page, so a page escaping all of them would be a considerable outlier". The direct experiment is the one [the measurement page][measurement] specifies for [SELF][self] — PSS and USS sampled across `N` concurrent processes — and it has not been run for Emacs here. Any claim about how much of a `pdumper` image is actually shared should come from `/proc/*/smaps_rollup`, not from this table.

The counterfactual is what makes this thesis-4 evidence rather than an anecdote. `unexec` _did_ preserve sharing and demand paging perfectly, because the artifact was an ELF file and `binfmt_elf` mapped it like any other. Emacs gave that up knowingly, and the reason given is not performance but that the technique _"might get in the way of various memory-layout techniques used by modern systems to enhance security and privacy"_. **The platform's threat model, not the format, is what killed the autological artifact.** Any proposal of the "the executable is X" family — [SELF][self] included — is proposing to re-enter a fight the incumbents already lost, and the only two moves known to work are SBCL's (partition, and map the immutable part shared) and CRIU's (don't carry the pages at all; reference and validate them).

### Dispatch

The dispatcher is the **loader**, in the narrow sense that the artifact is data and a specific runtime binary opens it. No image on this page is matched by the kernel on its magic; there is no `binfmt_misc` registration for `.image`, `.pdmp` or `.core`, and none of these projects has asked for one. The exceptions are the two configurations that stop being images: `save-lisp-and-die :executable t` produces an ELF the kernel executes directly, and an `escript` is dispatched by the _shell_, via `#!/usr/bin/env escript`. Compare [SELF][self], which is a database that the kernel is taught to execute via [`binfmt_misc`][binfmt] — precisely the move this tradition never made, and a plausible reason it never had to solve the identity problems that come with it.

### Trust

The trust story is dominated by one fact: **an image is a heap, and a heap contains function pointers.** Loading a hostile `.pdmp` or `.core` into a matching runtime is arbitrary code execution by construction, with no parsing bug required — the pointers are the payload. The mitigations are all identity checks rather than validation:

- Emacs compares a SHA-256-class fingerprint of the exact `temacs` and refuses on mismatch; the check is a build-identity check, not an authenticity check, and there is no signature anywhere in the format.
- SBCL declares runtime/core compatibility to be exact and _time_-sensitive: even same-source rebuilds are incompatible.
- CRIU validates every file-backed mapping's build-id before restoring, and the documentation is explicit that this is a security control: _"This prevents 'library injection' scenarios where an attacker might try to force a restored process to run against malicious versions of its original dependencies."_ ([`validate-files-on-restore.md`][criu-validate]).

CRIU additionally carries a real privilege surface. Checkpointing needs `CAP_SYS_ADMIN` or, since Linux 5.9, `CAP_CHECKPOINT_RESTORE`, plus `CAP_SYS_PTRACE` or a permissive `yama/ptrace_scope`, and the manual is blunt that _"Running criu as non-root has many limitations"_ ([`criu(1)`][criu-man]). A tool that can read any process's memory and reconstruct it with restored credentials is a capability that belongs in [the threat-model page][threat-model] alongside `binfmt_misc` registration.

Signing is unsolved here in the same way it is unsolved for [SELF][self], and for a sharper reason: a Squeak image's bytes change every time the developer saves, so any whole-file attestation is invalidated by normal use. Emacs sidestepped it by making the mutable half of the artifact disappear — a `.pdmp` is written once by a build and can be signed like any other build output, which is a real if unglamorous argument for the split. See [embedded provenance][provenance].

---

## The Lisp machines and Genera, briefly

The maximal case, and the one the current wave under-cites. The Symbolics 3600's architecture put type tags in hardware — _"Tagged architecture: run-time data-type checking with no overhead"_ ([3600 Technical Summary][symbolics-3600], February 1983) — with a demand-paged virtual memory in which the distinction between "program", "data" and "the running system" simply did not exist as a representational matter. Everything was an object with a tag; the compiler, the editor, the network stack and the paging system were inspectable objects in one address space; and the persistent artifact was a _world load_, the whole of that address space written out. Genera is the endpoint of the trajectory this page describes: maximal reflexivity, maximal mutability, an artifact that is unambiguously the program and its state and its own development environment.

It did not survive, and the reasons are the ones this page has been accumulating. The tagged-memory requirement made the system a _hardware_ proposition at exactly the moment stock RISC and x86 parts were pulling away on price and performance, so the substrate stopped being available. The single-address-space model — one protection domain, everything mutable, everything reachable — is orthogonal to the process isolation, W^X, and address-space randomization that commodity operating systems spent the following two decades making mandatory; it is the same collision that killed `unexec`, arriving earlier and at a larger scale. And the world load has every property catalogued above: no partial read, no signature, no sharing between world loads, and no query surface except by booting it.

The lineage's real successor is not a file format but an _architecture_ argument, and it belongs to [single-level store][sls] — IBM i/OS400, Multics, and the commercial system that actually shipped "the OS is a database". This page's contribution is the narrower observation that the failure mode was identical at both scales: **the reflexive artifact and the platform's memory protection model are in direct competition, and the platform wins.**

---

## Strengths

- **Start-up cost is paid once.** The mechanical justification is real and undefeated. Emacs, SBCL and Squeak all start in milliseconds with tens of megabytes of pre-built object graph available.
- **Self-interrogation at runtime is unmatched.** A Smalltalk image is the strongest example in the entire catalog of a program that can ask questions about itself, because the questioner and the subject are the same heap.
- **The image is the unit of reproducibility.** Whatever state you saved is the state you get. No configuration drift, no re-derivation, no "works on my machine" from a differently ordered load path.
- **Erlang's two-version rule is a genuine answer to a hard question.** Concurrent mutation of the code a running system is executing, with bounded memory, no locks on the read path, and a defined purge semantics. The catalog asks what a concurrent GC over a store somebody is executing from looks like; [`beam_bif_load.c`][beam-bif-load] contains one, complete with a dedicated `erts_literal_area_collector` process, copy-literals requests to every process in the system, and thread-progress barriers.
- **CRIU works on programs that were not designed for it.** Every other system here required its runtime to be built around the image. CRIU checkpoints arbitrary unmodified processes, and preserves `fork`-derived COW sharing across a restore by re-forking and comparing rather than by filling each VMA independently ([`copy-on-write-memory.md`][criu-cow]).
- **`crit` proves a memory image can have a query surface.** Binary → JSON → binary, because the schema is published. The only artifact on this page you can inspect and edit without running it.

## Weaknesses

- **Page sharing and demand paging are lost or heavily degraded** in every system that puts the heap in the artifact. Squeak loses both outright; Emacs keeps demand paging and loses sharing for 57% of its dump; SBCL keeps both only for the `:purify`-ed read-only space.
- **The artifact is welded to one exact binary.** Emacs's fingerprint, SBCL's "even runtimes built from the same sources at different times are incompatible", CRIU's build-id validation. An image is not portable; a _pair_ is.
- **Nothing at rest is queryable.** No index from name to offset, no schema, no tooling that is not the runtime itself. This is the gap that motivated [sqlelf][sqlelf] and [SELF][self].
- **Relocation metadata is a fifth of the artifact** in the one dump measured here, and exists only because the load address is not knowable in advance.
- **Signing is incompatible with the working model** wherever the program writes its own image, and this is the reason Emacs's split is defensible rather than merely a retreat.
- **The Smalltalk image is not one file.** `.image` plus `.changes` plus `.sources`, same basename, same directory, or method sources decompile to `t1`, `t2`.
- **Erlang's synchronized code replacement is not serializable**, and the documentation says so: processes created in the window between suspension and load run old code.
- **CRIU needs `CAP_CHECKPOINT_RESTORE` at minimum**, and cannot follow a process onto a host whose libraries differ — the build-id check turns a subtle corruption into a hard failure, which is the right trade and still a hard failure.
- **`unexec`'s removal deleted a capability, not just an implementation.** Nothing in Emacs 31 can turn a running Emacs into an executable, and the `pdumper` replacement is `-batch`-only by explicit `error`.

---

## Key design decisions and trade-offs

| Decision                                                                         | Rationale                                                                                                                                                   | Trade-off                                                                                                               |
| -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Emacs: replace `unexec` with an explicit heap serializer                         | ASLR, PIE and modern `malloc` made "re-emit the running process" unmaintainable; the manual frames it as not obstructing the platform's security techniques | The artifact stops being autological: two files, plus a fingerprint to bind them, plus 3.3 MiB of relocation tables     |
| Emacs: three regions (hot / discardable / cold)                                  | Only the never-relocated region can be mapped off the file with few COW faults — sharing is recovered where it can be                                       | The mappable region is 21% of the dump; the other 79% is private-dirty per process                                      |
| Emacs: fingerprint the exact `temacs` and refuse on mismatch                     | A dump is raw pointers into a specific binary's data segment; a near-match is a silent corruption                                                           | The dump has no independent existence, cannot be shared between builds, and is not signable as a standalone artifact    |
| Emacs: dumping is `-batch`-only                                                  | A dump taken from a live session would capture arbitrary user state and running threads                                                                     | The user-facing capability that made `unexec` interesting is gone; `pdumper` is a build tool                            |
| SBCL: `:purify` defaults to true, read-only space is `MAP_SHARED`                | Immutable objects (constant vectors, symbol names) can be mapped straight off the core and shared across processes                                          | Requires classifying the heap into mutable and immutable at save time; anything misclassified is a correctness bug      |
| SBCL: cores are runtime-specific, deliberately, including across rebuilds        | The alternative is a versioned external representation nobody was motivated to build ("no good quick fixes")                                                | Zero portability; distributing a core means distributing the runtime it was made with                                   |
| Squeak: read the heap into anonymous memory and swizzle every pointer            | Simplest possible loader; works identically on every platform the VM is ported to                                                                           | No file backing at all, so no sharing, no demand paging, and load time proportional to heap size                        |
| Squeak: image portable across VMs, VM native per platform                        | One artifact, N interpreters — portability moved to the substrate three decades before the catalog named the pattern                                        | The image alone is inert; and `.changes`/`.sources` must travel with it for sources to survive                          |
| CRIU: do **not** dump clean file-backed pages                                    | They can be re-mapped from the original files on restore, preserving sharing and demand paging and shrinking the image                                      | The image is not closed: restoring requires the same files on the destination, enforced only by a build-id check        |
| CRIU: images are schema'd protobufs in a directory                               | Gives `crit decode`/`encode`, partial reads, and per-concern evolution — self-description buying tooling                                                    | Not one file; the "artifact" is a directory whose members are only meaningful together                                  |
| CRIU: `in_parent` + soft-dirty + `--auto-dedup` hole punching                    | Iterative checkpoints store deltas, and restore frees blocks as it consumes them                                                                            | Dedup is only against the image's own ancestry chain, never content-global                                              |
| Erlang: exactly two live versions of a module, third load purges                 | Bounds memory and makes the lifetime of "old code" decidable; processes migrate by making a fully qualified call                                            | A process that never makes a qualified call is killed at the third load; the rule is a hard deadline, not a negotiation |
| Erlang: three code indices, one active, one staging, one quarantined             | Readers need no locks or barriers; the switch is a single publication                                                                                       | A code change must wait for thread progress before a released index can be reused                                       |
| Erlang: upgrades described by `.appup`/`relup` and executed by `release_handler` | State migration (`code_change/3`) is explicit and scriptable, with rollback by reboot into the old release                                                  | Not serializable — processes created mid-upgrade can run old code; the docs recommend small, backward-compatible steps  |

---

## Sources

- [`emacs-mirror/emacs`][emacs-repo] @ `b28750b8`: [`src/pdumper.c`][pdumper-c] (the dump header comment, the three regions, `dump_map_file_posix`, `pdumper_load`, the `-batch` restriction, the TODO list), [`doc/lispref/internals.texi`][internals-texi] (the `pdump` method, `dump-emacs-portable`, `pdumper-stats`), [`etc/NEWS.27`][news27] (the ASLR rationale), [`etc/NEWS.31`][news31] (removal), [`lib-src/make-fingerprint.c`][fingerprint-c] (the digest patched into `temacs`)
- [`src/unexelf.c`][unexelf-c] at `9ccd459e` — the 1982 header comment and the "we do not use mmap" note; removed by [`7ce34a3b`][unexec-removal] (2024-12-12), 4,666 lines across eleven files
- [`checkpoint-restore/criu`][criu-repo] @ `71285b3e`: [`Documentation/criu.txt`][criu-man] (`--file-validation`, the `NON-ROOT` section), [`Documentation/crit.txt`][crit-doc] (`decode`/`encode`/`x`), [`images/pagemap.proto`][pagemap-proto], [`images/mm.proto`][mm-proto], [`images/vma.proto`][vma-proto], [`criu/cr-restore.c`][criu-restore] (`restorer_get_vma_hint`), [`criu/files-reg.c`][criu-filesreg] (`BUILD_ID_MAP_SIZE`), and the under-the-hood notes on [memory dumping][criu-memdump], [COW restoration][criu-cow], [deduplication][criu-dedup], [file validation][criu-validate], [the restorer context][criu-restorer] and [restore stages][criu-stages]
- [`erlang/otp`][otp-repo] @ `15f55651`: [`system/doc/reference_manual/code_loading.md`][otp-codeload] (current/old, the `code_switch` example), [`system/doc/design_principles/release_handling.md`][otp-relhandling] (`update`, synchronized code replacement, the honest caveats), [`erts/emulator/beam/code_ix.h`][code-ix] (the three-index scheme), [`erts/emulator/beam/beam_bif_load.c`][beam-bif-load] (literal-area release), [`erts/doc/references/escript_cmd.md`][escript-doc] and [`lib/stdlib/src/escript.erl`][escript-erl] (shebang-prefixed archives)
- [`sbcl/sbcl`][sbcl-repo] @ `6b0c5fe4`: [`doc/manual/start-stop.texinfo`][sbcl-sld-src] (`save-lisp-and-die`, `:purify`, the incompatibility admission), [`src/runtime/os-common.c`][sbcl-oscommon] (`load_core_bytes`, `MAP_SHARED` for read-only space), [`src/runtime/coreparse.c`][sbcl-coreparse] (`LISP_FEATURE_ASLR`, `relocate_heap`)
- [`OpenSmalltalk/opensmalltalk-vm`][osvm-repo] @ `fb2be466`: [`src/spur64.stack/interp.c`][osvm-interp] (`readImageFromFileHeapSizeStartingAt`, segment swizzling), [`platforms/unix/vm/sqUnixSpurMemory.c`][osvm-mem] (anonymous heap allocation)
- [SBCL manual — Starting and Stopping][sbcl-sld] · [squeak.org documentation and FAQ][squeak-docs] (the `.image`/`.changes`/`.sources` trio) · ["Back to the Future: The Story of Squeak"][backtothefuture], OOPSLA 1997
- [Symbolics 3600 Technical Summary, February 1983][symbolics-3600] (tagged architecture) and [D. A. Moon, "Architecture of the Symbolics 3600", ISCA '85][moon-3600]
- Measured on this machine: the `emacs-30.2` Nix store output — `bin/emacs-30.2` (10,186,640 B) and its 17,719,896-byte `.pdmp`, header decoded against `struct dump_header` and cross-checked against the file size
- Runnable companion: [`elf-note-buildid.d`](./self-selfdb/examples/elf-note-buildid.d) — the build-id CRIU validates, read out of a live process's own image
- Related in this tree: [concepts][concepts] · [SELF / selfdb][self] · [single-level store][sls] · [ZIP parasitism][zip] · [`binfmt_misc`][binfmt] · [dynamic linking][ld] · [sqlelf][sqlelf] · [code as a database][code-as-db] · [embedded provenance][provenance] · [content-addressed chunking][chunking] · [SQLite as an application file format][sqlite-app] · [Nix store closures][nix-closures] · [measurement][measurement] · [threat model][threat-model] · [open questions][open] · [comparison][comparison] · [umbrella][index]

<!-- References -->

[emacs-repo]: https://github.com/emacs-mirror/emacs/tree/b28750b822dc45ffdceda3ea44a3c8b93f4e5a6b
[pdumper-c]: https://github.com/emacs-mirror/emacs/blob/b28750b822dc45ffdceda3ea44a3c8b93f4e5a6b/src/pdumper.c
[internals-texi]: https://github.com/emacs-mirror/emacs/blob/b28750b822dc45ffdceda3ea44a3c8b93f4e5a6b/doc/lispref/internals.texi
[news27]: https://github.com/emacs-mirror/emacs/blob/b28750b822dc45ffdceda3ea44a3c8b93f4e5a6b/etc/NEWS.27
[news31]: https://github.com/emacs-mirror/emacs/blob/b28750b822dc45ffdceda3ea44a3c8b93f4e5a6b/etc/NEWS.31
[fingerprint-c]: https://github.com/emacs-mirror/emacs/blob/b28750b822dc45ffdceda3ea44a3c8b93f4e5a6b/lib-src/make-fingerprint.c
[unexelf-c]: https://github.com/emacs-mirror/emacs/blob/9ccd459e8452cc9e6e81e53f26bbeef20d2d5bb7/src/unexelf.c
[unexec-removal]: https://github.com/emacs-mirror/emacs/commit/7ce34a3bcf5ed277ef37aa75e1ccbd858543b6cf
[criu-repo]: https://github.com/checkpoint-restore/criu/tree/71285b3e7abb0231acd49d558ccd489de1088892
[criu-man]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/Documentation/criu.txt
[crit-doc]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/Documentation/crit.txt
[pagemap-proto]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/images/pagemap.proto
[mm-proto]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/images/mm.proto
[vma-proto]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/images/vma.proto
[criu-restore]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/criu/cr-restore.c
[criu-filesreg]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/criu/files-reg.c
[criu-memdump]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/Documentation/under-the-hood/memory-dumping-and-restoring.md
[criu-cow]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/Documentation/under-the-hood/copy-on-write-memory.md
[criu-dedup]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/Documentation/under-the-hood/memory-images-deduplication.md
[criu-validate]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/Documentation/under-the-hood/validate-files-on-restore.md
[criu-restorer]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/Documentation/under-the-hood/restorer-context.md
[criu-stages]: https://github.com/checkpoint-restore/criu/blob/71285b3e7abb0231acd49d558ccd489de1088892/Documentation/under-the-hood/stages-of-restoring.md
[otp-repo]: https://github.com/erlang/otp/tree/15f5565172ad3c5d55370cbf2385c49d7c219a6a
[otp-codeload]: https://github.com/erlang/otp/blob/15f5565172ad3c5d55370cbf2385c49d7c219a6a/system/doc/reference_manual/code_loading.md
[otp-relhandling]: https://github.com/erlang/otp/blob/15f5565172ad3c5d55370cbf2385c49d7c219a6a/system/doc/design_principles/release_handling.md
[code-ix]: https://github.com/erlang/otp/blob/15f5565172ad3c5d55370cbf2385c49d7c219a6a/erts/emulator/beam/code_ix.h
[beam-bif-load]: https://github.com/erlang/otp/blob/15f5565172ad3c5d55370cbf2385c49d7c219a6a/erts/emulator/beam/beam_bif_load.c
[escript-doc]: https://github.com/erlang/otp/blob/15f5565172ad3c5d55370cbf2385c49d7c219a6a/erts/doc/references/escript_cmd.md
[escript-erl]: https://github.com/erlang/otp/blob/15f5565172ad3c5d55370cbf2385c49d7c219a6a/lib/stdlib/src/escript.erl
[sbcl-repo]: https://github.com/sbcl/sbcl/tree/6b0c5fe453d11f7820b8cc650d9ad8868bac1c6b
[sbcl-sld-src]: https://github.com/sbcl/sbcl/blob/6b0c5fe453d11f7820b8cc650d9ad8868bac1c6b/doc/manual/start-stop.texinfo
[sbcl-oscommon]: https://github.com/sbcl/sbcl/blob/6b0c5fe453d11f7820b8cc650d9ad8868bac1c6b/src/runtime/os-common.c
[sbcl-coreparse]: https://github.com/sbcl/sbcl/blob/6b0c5fe453d11f7820b8cc650d9ad8868bac1c6b/src/runtime/coreparse.c
[sbcl-sld]: https://www.sbcl.org/manual/#Starting-and-Stopping
[osvm-repo]: https://github.com/OpenSmalltalk/opensmalltalk-vm/tree/fb2be46609cfbf69053e86e869a4dd82fdde6ead
[osvm-interp]: https://github.com/OpenSmalltalk/opensmalltalk-vm/blob/fb2be46609cfbf69053e86e869a4dd82fdde6ead/src/spur64.stack/interp.c
[osvm-mem]: https://github.com/OpenSmalltalk/opensmalltalk-vm/blob/fb2be46609cfbf69053e86e869a4dd82fdde6ead/platforms/unix/vm/sqUnixSpurMemory.c
[squeak-docs]: https://squeak.org/documentation/
[backtothefuture]: https://dl.acm.org/doi/10.1145/263698.263754
[symbolics-3600]: https://archive.org/details/bitsavers_symbolics3calSummaryFeb83_17982039
[moon-3600]: https://dl.acm.org/doi/10.1145/327070.327133
[concepts]: ./concepts.md
[self]: ./self-selfdb/index.md
[sls]: ./single-level-store.md
[zip]: ./zip-parasitism.md
[binfmt]: ./binfmt-misc.md
[ld]: ./dynamic-linking.md
[sqlelf]: ./sqlelf.md
[code-as-db]: ./code-as-database.md
[provenance]: ./embedded-provenance.md
[chunking]: ./content-addressed-chunking.md
[sqlite-app]: ./sqlite-application-file-format.md
[nix-closures]: ./nix-store-closures.md
[measurement]: ./measurement.md
[threat-model]: ./threat-model.md
[open]: ./open-questions.md
[comparison]: ./comparison.md
[index]: ./index.md
