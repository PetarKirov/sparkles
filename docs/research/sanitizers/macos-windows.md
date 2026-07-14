# Beyond Linux: macOS and Windows

The two columns the sparkles runner meets when it leaves Linux. macOS keeps the
full LLVM [`compiler-rt`][runtime-selection] lineage for C/C++ but reaches D only
as a dylib-linked afterthought; Windows narrows the set to AddressSanitizer (plus
`kernel-address` and libFuzzer), swaps ELF symbol interposition for runtime
hotpatching, and leans on **Dr. Memory** as the no-recompile stand-in for the
Valgrind role. This page walks each column through the survey's
[seven concerns][concepts] and closes with what both mean for the runner's probes.

| Field                          | Value                                                                                                                                                                                                                                                                                               |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS surface                  | Apple clang ASan/TSan/UBSan for **C/C++** (`aarch64-darwin`); LDC reaches ASan/TSan/LSan as **dylib-only** runtimes                                                                                                                                                                                 |
| Windows surface                | MSVC `/fsanitize=address` + `kernel-address` + `fuzzer` **only**; LDC ships `ldc_rt.asan` + libFuzzer; **Dr. Memory** (DBI) for DMD                                                                                                                                                                 |
| [Instrumentation locus][locus] | macOS: same **LLVM IR pass** as Linux · Windows: IR pass + runtime **hotpatch** [interceptors][interceptor]; Dr. Memory = **binary translation** (DynamoRIO)                                                                                                                                        |
| Reachable from                 | macOS: Apple clang (C), **LDC** (D, cc-fallback dylib) — not DMD · Windows: MSVC (C), **LDC** (D, ASan/fuzzer) — not DMD (Dr. Memory only), not GDC/MinGW                                                                                                                                           |
| Runtime model                  | macOS: `libclang_rt.*_osx_dynamic.dylib` (dylib-only) · Windows: `clang_rt.asan_dynamic-*.dll` + per-CRT thunk import libs (DLL-only since LLVM 20)                                                                                                                                                 |
| Structural absences            | macOS: Valgrind dead past 10.13; UBSan unreachable from D · Windows: no TSan/LSan/MSan/UBSan/HWASan; zero `arm64` runtimes                                                                                                                                                                          |
| Versions                       | LDC **1.41.0** (source read at tag `v1.41.0`) · compiler-rt [`73802c2e`][llvm-src] · MS Learn `ms.date` **2026-05-28** · Dr. Memory **2.6.0** + cronbuilds · valgrind **3.26.0**                                                                                                                    |
| Verification                   | **`[source-verified]`** LDC driver/CMake source, official release-tarball + `cache.nixos.org` NAR listings, compiler-rt source · **`[literature]`** MS Learn, valgrind.org, upstream issues/PRs · **`[hw-verified: aarch64-darwin]` for exactly one datum** — the recon Apple-clang ASan smoke test |

> [!IMPORTANT]
> **Verification level, stated honestly.** The macOS column is **mechanism-verified,
> not run-verified.** The planned `mac-bsn` (Apple **M4 Max**, macOS 26.3.1, SIP on)
> hardware experiments were **blocked** — the only usable ssh key sat locked in
> `gpg-agent` with no pinentry surface for the tty-less session — so no D-on-darwin
> sanitizer transcript, no TSan/UBSan/LSan run, and no darwin overhead number landed.
> What _is_ verified: every link-mechanism and packaging claim from LDC v1.41.0
> source, official release-tarball listings, and `cache.nixos.org` NAR listings
> (`[source-verified]`), plus **one** hardware datum — the recon Apple-clang ASan
> heap-use-after-free smoke test (`[hw-verified: aarch64-darwin]`). A zero-thought
> rerun kit is staged (`scratchpad/w6/fixtures/`) and the gap is tracked as an open
> **Q-row** in the survey's internal grounding register; everything below marked
> _pending hardware verification_ awaits that rerun. **The Windows column has no
> hardware at all** — it is documentation and open source only, tagged `[literature]`
> and `[source-verified]`, never `[hw-verified]`.

---

## Overview

### What changes off Linux

Both non-Linux columns share the Linux columns' _instrumentation_ but diverge on
_runtime, packaging, and policy_. macOS uses the identical [LLVM IR pass][locus] —
so LDC's `-fsanitize=address` produces the same instrumented object — but the
runtime is a **dylib only**, the process **aborts** on a finding instead of
`exit(1)`, and a `libmalloc` hygiene knob is mandatory. Windows keeps the same
compiler-rt report shape (`==PID==ERROR: AddressSanitizer:`, LLVM-symbolized
frames) but reaches uninstrumented code by **hotpatching** function prologues
rather than ELF interposition, ships ASan as a DLL only, and offers no TSan, LSan,
MSan, UBSan, or HWASan at all. Off Linux, the survey's blunt summary holds: the
sanitizer columns end at the Linux border **except AddressSanitizer**.

### Design philosophy: two curated islands

Like the [macOS CPMU story][cpu-pmu-macos] in the sibling survey, Apple and
Microsoft both _curate_ where Linux exposes. Apple ships one runtime form (the
dylib), sets safe operational defaults (`abort_on_error=1`), and expects tools to
link its own `compiler-rt` build; Microsoft ships one sanitizer (ASan) wrapped in a
first-class MSVC/Visual Studio experience — a runtime hotpatch model, a
`continue_on_error` recover mode with report dedup and a crash-dump path, and an
explicit, published roadmap of what does _not_ yet exist. Neither exposes the open
`-fsanitize=` menu D developers get on Linux, and the practical upshot for a
portable runner is the survey's recurring one: **"sanitizer available" must be a
runtime capability probe, never an assumption.**

---

## macOS (Apple clang / LDC on `aarch64-darwin`)

macOS is the survey's _second_ real bed — the recon smoke test proves Apple clang
ASan works end-to-end on the M4 Max — but the D toolchain reaches
it only through a link-time fallback, and the hardware runs that would have exercised
that fallback were blocked (see the scope note above).

### Defect classes and blind spots

The catchable defect classes are the Linux ASan/TSan set. The one datum that landed
on hardware: **Apple clang 21.0.0 ASan on the M4 Max catches heap-use-after-free
with allocation-site `file:line` symbolization and dies with `SIGABRT`** (shell exit
**134**, `Abort trap: 6`) under default env — consistent with the darwin
`abort_on_error=1` default. `[hw-verified: aarch64-darwin]`

```text
$ clang -fsanitize=address -g uaf.c -o uaf-asan && ./uaf-asan   # mac-bsn, uid 501
==61730==ERROR: AddressSanitizer: heap-use-after-free on address 0x6020000000d0 …
    #0 0x000104ffc60c in main uaf.c:2
exit: 134    (Abort trap: 6)
```

Everything richer than that catch is _pending hardware verification_. Two structural
findings hold regardless of the blocked runs:

- **UBSan is unreachable from D on darwin too** — not an OS gap but a compiler one:
  UBSan is [clang-CodeGen-only][locus] with no IR pass for LDC to borrow, exactly as
  on Linux (see [ubsan.md][ubsan]). Apple clang's UBSan works for **C/C++** and
  Apple's darwin `compiler-rt` ships `libclang_rt.ubsan_osx_dynamic.dylib`, but D
  code emits none of the checks. `[source-verified]`
- **The [GC memory blind spot][gc-blind-spot] is unchanged**, because it is a
  property of the D allocator (GC pools come from `mmap`, outside any sanitizer
  allocator), not of the OS. A use-after-free _inside_ GC memory is invisible to
  darwin ASan for the same reason it is on Linux.

**LeakSanitizer on Apple Silicon** is the sharpest open question. Upstream
`compiler-rt` _does_ define leak-checking as available on arm64-darwin —
`CAN_SANITIZE_LEAKS` is `1` for `(SANITIZER_LINUX || SANITIZER_APPLE)` on 64-bit
`__aarch64__` ([`lsan_common.h`][compiler-rt-lsan]) — and, remarkably, the official
LDC osx-universal package **ships `libldc_rt.lsan.dylib` for arm64** (artifact
listing below). Whether _Apple's own_ clang build enables it — Apple has
historically shipped no lsan runtime and hard-disabled `detect_leaks` — is the
untested hardware question. `[source-verified]` for the source and package facts;
the Apple-clang enablement is _pending hardware verification_.

### Instrumentation model and recompile scope

The IR pass and what-must-recompile are **identical to the Linux ASan column**
([asan.md][asan]); only the _runtime linking_ is darwin-specific, and it is
dylib-only. LDC's linker driver states the constraint verbatim in
`addSanitizerLinkFlags` ([`driver/linker-gcc.cpp`][ldc-linker-gcc], v1.41.0):

> _"On Darwin, the only option is to use the shared library."_

Concretely, when LDC finds a runtime dylib in its lib dirs it links it plus **two
`-rpath` entries** (`@executable_path` and the dylib's directory); when it finds
none, it **falls back to appending the raw `-fsanitize=address` flag to the C
compiler used as linker driver** ("Fallback, requires Clang"). `[source-verified]`

Which branch fires depends entirely on packaging, and this is the crux of the whole
column. The nixpkgs `aarch64-darwin` LDC was artifact-verified **without a Mac**, off
`cache.nixos.org` NAR listings, to be the same shape as the Linux column: it ships
**no** sanitizer runtime and carries a **dangling** compiler-rt lib-dir in its baked
`ldc2.conf`.

```text
$ nix store ls --store https://cache.nixos.org -R $ldc/lib | grep -iE '`ldc_rt`|`clang_rt`'
./`ldc_rt`.dso.o                                             # the ONLY rt artifact
$ nix store cat … $ldc/etc/ldc2.conf | grep -A2 lib-dirs
    lib-dirs = [ ".../ldc-1.41.0/lib",
        ".../llvm-18.1.8-lib/lib/clang/18/lib/darwin", // compiler-rt directory
$ nix store ls … .../llvm-18.1.8-lib/lib/clang/
error: path '«unknown»/lib/clang' does not exist          # the dir DANGLES
```

So the search fails and the fallback engages: `-fsanitize=address` is handed to
`cc`, and **the sanitizer runtime then comes from whatever `cc` provides.** Both
realistic `cc`s satisfy it — a bare-Mac `/usr/bin/clang` (Apple, recon-proven to
work) and a nixpkgs devshell clang (nixpkgs darwin `compiler-rt` **21.1.7** ships
the full darwin set: `libclang_rt.{asan,lsan,tsan,ubsan,rtsan}_osx_dynamic.dylib`).
`[source-verified]` The verdict: **D + ASan on darwin stands or falls with the C
toolchain on `PATH`, not with LDC itself** — a moving dependency the runner would
have to pin, and precisely the kind of environment coupling the probes' SKIP
discipline exists to avoid. The end-to-end run transcript that would confirm this
chain is _pending hardware verification_.

### D and druntime interaction

The [druntime interaction surface][fake-stack] is OS-independent in its essentials:
the LDC druntime fork carries the `SupportSanitizers` [fiber-annotation][fake-stack]
machinery (ASan fake-stack scanning, `informSanitizerOfStartSwitchFiber`), no
shipped build turns it on, and basic fiber operation is sound anyway because the
faulting access is in instrumented user code (see [d-toolchain.md][d-toolchain]).
None of that changes on darwin — the fixture ports (heap-UAF, stack-UAR, global
overflow, data race, fiber UAR) are hand-ported and staged, but their darwin
transcripts are _pending hardware verification_. The GC blind spot and the fake-stack
GC-scan hazard are allocator-architecture facts, identical to the Linux column.

### Runtime control and report capture

Two darwin defaults differ operationally from Linux and both matter to a runner. The
first is the death mode. LDC's own test suite pins it ([`tests/sanitizers/lit.local.cfg`][ldc-lit], v1.41.0):

> _"On Darwin, ASan defaults to `abort_on_error=1`, which would make tests run much
> slower."_

So a darwin ASan finding raises `SIGABRT` — **shell exit 134**, hardware-confirmed by
the recon smoke test — where Linux `clang_rt`/GCC-libasan `exit(1)`. That single
number breaks every probe assertion that checks `code == 1` (see the
[halt-vs-recover][halt-vs-recover] matrix, whose darwin row records exactly this).
The runner's normalization is `ASAN_OPTIONS=abort_on_error=0` to fold the death back
to `exit(1)` conventions. `[source-verified]` + `[hw-verified: aarch64-darwin]`

The second is a `libmalloc` hygiene requirement. `compiler-rt`'s own unit-test
harness sets `MallocNanoZone=0` on Darwin, with the reason inline
([`unittests/lit.common.unit.cfg.py`][compiler-rt-nanozone]):

> _"Disable libmalloc nano allocator due to crashes running on macOS 12.0.
> rdar://80086125"_

Without it, the sanitizer shadow collides with the address range the nano allocator
wants, and `libmalloc` prints a startup warning (the widely-observed
`malloc: nano zone abandoned …` family) that would pollute any `[Output]`-style
verification. `[source-verified]` for the compiler-rt env-set; the exact warning text
on the M4 Max is _pending hardware verification_. The minimal darwin env recipe is
therefore:

```bash
MallocNanoZone=0 ASAN_OPTIONS=abort_on_error=0:detect_leaks=0 ./app   # ASan
MallocNanoZone=0 TSAN_OPTIONS=halt_on_error=0 ./app                   # TSan
```

The [weak-hook control surface][weak-hooks] (`__asan_set_error_report_callback`,
`log_path`, `__asan_default_options`) is a `compiler-rt` API and available in the
darwin dylib exactly as on Linux — but note the runner would be talking to
_whichever_ `compiler-rt` the cc-fallback linked (Apple's or nixpkgs'), a further
reason to pin the toolchain. `log_to_syslog=0` is the customary darwin companion so
reports go to stderr, not the system log.

### Symbolization and suppressions

Symbolization inputs differ structurally from Linux, as the [CPU-PMU macOS
page][cpu-pmu-macos] documents for the same box: `file:line` needs Mach-O + a
**dSYM** (DWARF) bundle resolved by `atos` (engine: the closed
`CoreSymbolication.framework`), and a one-shot `clang -g src.c -o bin` yields an
_empty_ dSYM because `dsymutil` needs the intermediate `.o` retained — the darwin
analog of the Linux build-id/stale-binary hazard. Apple's darwin `compiler-rt`
self-symbolizes with `atos`/`CoreSymbolication` rather than `llvm-symbolizer`; a
nixpkgs-clang runtime would want `llvm-symbolizer` on `PATH` as on Linux. The
[suppression][suppression] story is unchanged — one-line `type:pattern` globs matched
against **mangled** D names, because no `compiler-rt` runtime demangles D. The
darwin-specific symbolization transcript is _pending hardware verification_.

### Test-runner integration semantics

The one integration delta that is _not_ speculative is the **exit-code mapping**: a
darwin ASan failure is `SIGABRT`/**134**, not **1**, so the runner's "sanitizer
finding" classifier needs a darwin arm, and probes that assert a specific exit code
are Linux-runtime-specific by construction. Two platform notes bound any future
darwin runner leg:

- **SIP + `DYLD_INSERT_LIBRARIES`.** System Integrity Protection strips
  `DYLD_INSERT_LIBRARIES` when spawning SIP-protected binaries (`/usr/bin/*` and
  friends), so runtime-injection tricks work only on the runner's _own_ built
  binaries — record, don't fight. `csrutil status` reports SIP enabled on `mac-bsn`.
- **The cc-fallback coupling** (above) means the darwin CI leg's sanitizer runtime is
  a moving dependency on the toolchain in the shell — the runner would pin it to the
  nixpkgs clang.

Whether darwin [TSan][tsan]'s [report-and-continue][halt-vs-recover] semantics and
druntime-race suppression behave as on Linux is _pending hardware verification_
(darwin TSan _exists_ — `lit.local.cfg` feature-gates it ON for Darwin while OFF for
Windows — but was not run here). `[source-verified]`

### Platform, toolchain, and overhead

The link-mechanism chain is covered above; the packaging facts complete it. The
**official** LDC release does what nixpkgs does not — it bundles Apple's `compiler-rt`
sanitizer dylibs, renamed. CMake copies `libclang_rt.asan_osx_dynamic.dylib` →
`libldc_rt.asan.dylib` (plus lsan, tsan) under `LDC_INSTALL_LLVM_RUNTIME_LIBS`
([`CMakeLists.txt`][ldc-cmake], v1.41.0), and the shipped
`ldc2-1.41.0-osx-universal.tar.xz` was **artifact-verified** to carry them for both
architectures:

```text
$ tar -tf ldc2-1.41.0-osx-universal.tar.xz | grep -iE '`ldc_rt`|`clang_rt`'
…/lib-arm64/libldc_rt.{asan,lsan,tsan}.dylib
…/lib-arm64/libldc_rt.{fuzzer,profile,builtins,xray,xray-basic,…}.a
(same set under lib-x86_64/; lib-ios-*/ has only `ldc_rt`.dso.o — no sanitizers for iOS)
```

`[source-verified]` So an **official-LDC** user on Apple Silicon links `ldc_rt`
directly (the found-dylib branch), while the **nixpkgs-LDC** user takes the
cc-fallback — two different runtime provenances behind the same `-fsanitize=address`.

**Valgrind is definitively dead on modern macOS**, so the no-recompile lane the DMD
user relies on elsewhere does not exist here. Upstream 3.26.0's `configure.ac`
hard-errors on any Darwin kernel newer than 17.x, and the platforms page confirms the
cap:

> _"X86/Darwin (10.5 to 10.13), AMD64/Darwin (10.5 to 11.0): supported."_
> — [valgrind.org/info/platforms.html][valgrind-platforms]

i.e. the last supported macOS is **10.13** (2017), x86 only, with **no**
Apple-Silicon port at all. `[literature]` The single arm64 option is the out-of-tree
[`LouisBrunner/valgrind-macos`][louisbrunner] fork — a one-maintainer patch series
outside the Valgrind repo and outside nixpkgs, not viable as a CI dependency. Full
treatment is in [valgrind.md § platform and toolchain coverage][valgrind-platform].
**Overhead: no darwin sanitizer timings were measured** (hardware blocked) — the
overhead concern is unanswered for this column.

---

## Windows (MSVC / LDC / Dr. Memory)

Documentation-and-source only, explicitly **not** hardware-verified. Two toolchains
matter: MSVC (the `compiler-rt` lineage with a Windows interception model) reachable
from LDC for D, and Dr. Memory (DynamoRIO binary translation) as the no-recompile
analog DMD is stuck with.

### Defect classes and blind spots

MSVC's `/fsanitize` accepts **exactly three** values — `address`, `kernel-address`
(KASan; VS 2022 17.11+, Windows 11 24H2+), and `fuzzer` (experimental libFuzzer) —
with no comma syntax and no TSan/LSan/MSan/UBSan/HWASan. The overview page states
the ceiling and, in one sentence, the entire absence
([MS Learn, AddressSanitizer overview][msvc-asan], `ms.date` 2026-05-28):

> _"Support is limited to x86 and x64 on Windows 10 and later."_
>
> _"Your feedback helps us prioritize other sanitizers for the future, such as
> `/fsanitize=thread`, `/fsanitize=leak`, `/fsanitize=memory`, `/fsanitize=undefined`,
> or `/fsanitize=hwaddress`."_

`[literature]` The catchable classes are the ASan set (heap/stack/global overflow,
use-after-free, use-after-return). **Dr. Memory adds two classes ASan misses** —
uninitialized reads (a [definedness][definedness] check ASan structurally lacks) and,
uniquely, **Windows handle leaks / GDI misuse** — which its README enumerates
verbatim ([`README`][drmemory] @ `3d2b5f9`):

> _"…accesses of uninitialized memory, accesses to unaddressable memory…, accesses to
> freed memory, double frees, memory leaks, and (on Windows) handle leaks, GDI API
> usage errors, and accesses to un-reserved thread local storage slots."_

`[source-verified]` The **D GC blind spot** is unchanged for both tools: D GC pools
come from `VirtualAlloc`, not `malloc`/`HeapAlloc`, so in-pool use-after-free and
intra-pool overflow are invisible — the same [allocator-boundary][gc-blind-spot] fact
established for ASan and memcheck. `[source-verified reasoning]` (no Windows hardware.)

### Instrumentation model and recompile scope

MSVC ASan is compile-time instrumentation (the `compiler-rt` lineage — runtimes are
literally `clang_rt.asan_dynamic-{i386,x86_64}.lib`/`.dll`), but its
[interception][interceptor] of uninstrumented code is **runtime hotpatching**, not
ELF interposition — and that hotpatch can _fail at runtime_
([MS Learn, AddressSanitizer runtime][msvc-asan-runtime]):

> _"The AddressSanitizer achieves function interception through many hotpatching
> techniques. … If a function prologue is too short for a jmp to be written,
> interception can fail. If an interception failure occurs, the program throws a
> debugbreak and halts."_

`[literature]` This is a class of failure with **no ELF-world equivalent** — a
"sanitizer-infrastructure" halt a Windows runner would have to classify separately
from an actual finding. The shadow mapping is also Windows-specific: on x64 the
shadow offset is **runtime-assigned**, not Linux's fixed `0x7fff8000`
(`shadow = *((addr >> 3) + _asan_runtime_assigned_offset)`; x86 keeps a constant
`0x30000000`). `[literature]` ([asan-shadow-bytes][msvc-asan-shadow]).

**Dr. Memory recompiles nothing** — it is [binary translation][locus] via DynamoRIO,
re-translating every machine instruction at run time, so it instruments any user-mode
PE binary including DMD output (DMD has zero sanitizer flags, so this is DMD's only
Windows path). It is the Windows structural cousin of Valgrind's VEX JIT; the
contrast between the two DBI engines is drawn in [valgrind.md][valgrind].

### D and druntime interaction

- **DMD on Windows = Dr. Memory only** (no recompile; DMD emits CodeView with `-g`,
  `-gf` for full, so callstacks resolve via PDB). `[source-verified reasoning]`
- **LDC on Windows links ASan/libFuzzer from libs it ships itself** — but a known
  D-specific defect gates it. `linker-msvc.cpp` pushes `ldc_rt.asan.lib` (+ a
  per-CRT `ldc_rt.asan_{static,dynamic}_runtime_thunk.lib` since LLVM 20), or
  `ldc_rt.fuzzer.lib`, and the function ends `// TODO: remaining sanitizers` —
  **there is no TSan/MSan link path on Windows.** `[source-verified]`
  ([`driver/linker-msvc.cpp`][ldc-linker-msvc], v1.41.0.)

> [!WARNING]
> **"Ships" ≠ "works for idiomatic D."** LDC ships working ASan libs on Windows, yet
> **D exceptions break under them** — [ldc issue #3760][ldc-3760] ("Windows:
> `-fsanitize=address` doesn't work with exceptions", open since **2021-06-12**, still
> open as of 2026-07-11): throwing a D exception in a constructor under
> `-fsanitize=address` surfaces as an access-violation report instead of normal
> unwinding (related: #3742 — LDC has no SEH integration for hardware faults). Any
> Windows D + ASan recommendation must carry this caveat: it is realistically limited
> to exception-light / `-betterC`-style code until fixed. `[literature]`

**GDC is a non-option** — GCC-based MinGW-w64 toolchains do not build `libsanitizer`
(msys2/MINGW-packages [#3163][msys-3163]: `-fsanitize=address` → link error), so even
where a MinGW GDC exists there is no ASan runtime to link; the MinGW-ABI toolchain
that _does_ ship sanitizers is llvm-mingw (clang-based), which does not help D.
`[literature]`

### Runtime control and report capture

Windows' analog of the [halt-vs-recover][halt-vs-recover] matrix inverts the Linux
split: the **recover** knob is env-only while **use-after-return** detection moves
into a **compile flag** — the exact opposite of `clang_rt`.

- **Recover = `ASAN_OPTIONS=continue_on_error` (COE)** — VS 2022 17.6+; `1` = stdout,
  `2` = stderr, `COE_LOG_FILE=` for a file. Unlike clang's `halt_on_error=0` (which
  needs code compiled `-fsanitize-recover=address`), **COE needs no recompile flag**,
  continues past recoverable errors, **deduplicates by unique call stack**, and prints
  an end-of-run summary. It cancels on uncatchable faults with a sentinel line:

  > _"CONTINUE CANCELLED - Deadly Signal. Shutting down."_
  > — [MS Learn, ASan continue-on-error][msvc-asan-coe]

  So COE ≈ (`-fsanitize-recover=address` + `halt_on_error=0`) folded into one runtime
  env var, _plus_ stack-dedup and a summary that `clang_rt` lacks. The default (no
  COE) is fail-fast like clang. `[literature]`

- **Use-after-return inverts** — stack-use-after-return "requires an extra compiler
  option (`/fsanitize-address-use-after-return`)" and "isn't available by only setting
  `ASAN_OPTIONS`", while clang always emits the [fake-stack][fake-stack]
  instrumentation and gates it at run time via `detect_stack_use_after_return`.
  (`stack-use-after-scope` is conversely on-by-default and can't be turned off.) A
  Windows feature matrix must key on **compile flags**, not env vars. `[literature]`
- **Crash dumps for the IDE** — `ASAN_SAVE_DUMPS=MyFileName.dmp` writes a dump with
  ASan metadata that Visual Studio's debugger opens at the fault site, the Windows
  substitute for a stderr report walked in a terminal. `[literature]`

For Dr. Memory the control surface is command-line: results land in
`logs/DrMemory-<app>.<pid>.NNN/results.txt`; `-results_to_stderr` is default-true
(per-line `~~Dr.M~~` prefix; `-prefix_style 2` makes output Visual-Studio
file/line-parseable); on Windows it auto-opens Notepad at exit unless `-batch`.
`[source-verified]` ([`optionsx.h`][drmemory], `docs/using.dox`.)

### Symbolization and suppressions

MSVC ASan symbolizes through **PDB + the LLVM symbolizer**, with the classic
`==PID==ERROR: AddressSanitizer:` report shape and internal frames pointing at
`…\compiler-rt\lib\asan\asan_malloc_win_thunk.cpp`. `[literature]` Dr. Memory reads
CodeView/PDB for callstacks but **has no D demangler** (it demangles C++ only), so
`_D…` symbols print mangled — where memcheck ships a D demangler since 3.14 (see
[valgrind.md][valgrind]). `[source-verified reasoning]` [Suppressions][suppression]
differ per tool: ASan's one-line `type:pattern` globs (matching **mangled** D names)
versus Dr. Memory's block format — an error-type line plus `module!function` or
`<module+0xoff>` frames with `*`/`?`/`...` wildcards, ellipsis frames, and a Windows
`instruction=` restriction. `[source-verified]` MSVC explicitly has **no ignorelist**
— "Special case list files are unsupported" — so LDC's `-fsanitize-blacklist` has no
MSVC-runtime analog. `[literature]` ([asan-known-issues][msvc-asan-known-issues].)

### Test-runner integration semantics

The Windows exit-code story is a **third** convention distinct from both Linux tools.
COE leaves the app's own exit behavior in play (continue past recoverable errors);
default ASan is fail-fast. **Dr. Memory preserves the app's exit code by default** —
`-exit_code_if_errors <int>` defaults to `0` (= don't change it), so findings **do
not fail CI unless opted in**, the same footgun family as valgrind's opt-in
`--error-exitcode` but for the Windows-native tool. `[source-verified]` MSVC ASan is
also **incompatible with a runner-relevant list**: `/RTC*`, incremental linking,
Edit-and-Continue, OpenMP, managed C++, and UWP are unsupported, and — the Windows
cousin of the D-fibers concern — _"Coroutines are incompatible with
AddressSanitizer, and resumable functions are exempt from instrumentation."_
`[literature]` The natural Windows IDE flow is the ASan crash dump opened in Visual
Studio (above), the substitute for the in-process [report-windowing][halt-vs-recover]
patterns the Linux columns use.

### Platform, toolchain, and overhead

MSVC ASan is **x86/x64 only** (the overview quote above). The official LDC Windows
package was **artifact-verified** to match the source: both `lib32/` and `lib64/`
carry `clang_rt.asan_dynamic-{i386,x86_64}.dll`, `ldc_rt.asan.lib`, both thunk libs,
and `ldc_rt.{builtins,fuzzer,profile}.lib` — and **no** lsan/tsan/msan libs — so the
official Windows binary is sanitizer-ready out of the box for ASan + libFuzzer only.
LSan is explicitly excluded (CHANGELOG 1.30.0: _"New LeakSanitizer support via
`-fsanitize=leak` (not (yet?) supported on Windows). (#4005)"_). `[source-verified]`
Two packaging facts complete the picture:

- **The static ASan runtime was eliminated upstream in LLVM 20** (llvm-project
  [PR #93770][llvm-pr-93770]) — Windows ASan is DLL-only with per-CRT thunk import
  libs, mirroring MSVC's VS 17.7 "one DLL for all runtime configurations". This is why
  LDC's `linker-msvc.cpp` grew its `LDC_LLVM_VER >= 2000` thunk branch. `[literature]`
  - `[source-verified]`
- **Windows-on-ARM64 ships zero sanitizer runtimes.** The official
  `ldc2-1.41.0-windows-multilib.7z` `libarm64/` directory contains **only**
  `ldc_rt.dso.obj` — so `-fsanitize=address` on windows-arm64 D has no packaged
  runtime to link. `[source-verified]` The Windows sanitizer column is silently
  x86/x64-only for D too, matching MSVC's stated limit.

> [!NOTE]
> **WinDbg Time Travel Debugging is the companion, not a sanitizer.** TTD records a
> full user-mode execution trace (no recompile, any PE binary incl. DMD output) and
> replays it deterministically with reverse execution and memory-history queries. It
> performs **no validity checking** — it finds nothing by itself; a Windows D
> developer reaches for it _after_ an ASan/Dr. Memory/crash report, to walk backward
> from a corruption site to the writer (data breakpoint + reverse-continue answers
> "who wrote this byte"). Overhead ~10–20× while recording. `[literature]`
> ([WinDbg TTD overview][windbg-ttd].)

**Maintenance verdict — Dr. Memory is coasting.** The last _official_ release is
**2.6.0 (July 2022)**; since then only auto-generated weekly "cronbuilds" (latest
seen `cronbuild-2.6.20434`, 2025-12-13) against a still-active repo (HEAD 2025-12-12).
Usable, but expect stale symbol support for the newest toolchains and no imminent 2.7
— alive enough to use, not enough to bet a CI lane on for new-toolchain PDBs.
`[source-verified]` (clone HEAD) + `[literature]` ([releases][drmemory-releases]).
**Overhead: no Windows hardware, so no measured slowdown** — the overhead concern is
unanswered for this column, as for macOS.

---

## Probe portability: all eleven stay `platforms "linux"`

Both columns are rich, but their value to sparkles is _comparative_ — what changes
when the runner leaves Linux — not a set of CI-executed probes. The verdict for the
[batch-1 probes][asan] is unanimous: **all eleven keep `platforms "linux"`.** They
are Linux-locked at **three independent layers** — the dub `platforms "linux"` key,
a `version (linux)` guard around the demo body, and
`import core.sys.linux.dlfcn` for the dlsym feature-detection — so a darwin leg is a
**port, not a `platforms` toggle**. Four runtime facts seal it: darwin ASan dies by
`SIGABRT`/**134** (so every `code == 1` assertion is wrong), probes that assert
GCC-libasan self-symbolization wording are Linux-runtime-specific, `[Output]`
verification would be polluted by the `libmalloc` nano-zone warning unless every leg
sets `MallocNanoZone=0`, and the macOS CI row's LDC gets its runtime via the moving
[cc-fallback](#platform-toolchain-and-overhead). The `ci` helper **enforces**
`platforms "linux"` itself (it `⊘`-skips non-matching files), so the probes are
clean no-ops on the macOS CI row — nothing breaks either way.

| Probe                        | Verdict                | What a darwin port would take                                                         |
| ---------------------------- | ---------------------- | ------------------------------------------------------------------------------------- |
| `asan-heap-uaf.d`            | keep `platforms linux` | exit 1→134; `abort_on_error=0`, `MallocNanoZone=0`, symbolizer-agnostic checks        |
| `asan-stack-uar.d`           | keep linux             | same + UAR default differs per runtime (GCC-on; darwin `clang_rt` needs verifying)    |
| `asan-global-overflow.d`     | keep linux             | same exit-code/symbolizer coupling                                                    |
| `asan-report-capture.d`      | keep linux             | callback verified vs GCC libasan; darwin `clang_rt` dylib needs separate verification |
| `lsan-gc-interplay.d`        | keep linux             | LSan-on-darwin is the single most uncertain darwin fact; also `core.sys.linux.dlfcn`  |
| `tsan-data-race.d`           | keep linux             | darwin TSan exists, but `MallocNanoZone` noise + exit codes + suppressions unverified |
| `gc-uaf-blindspot.d`         | keep linux             | blind-spot demo is allocator-architecture based; darwin adds nothing                  |
| `fiber-asan.d`               | keep linux             | fake-stack + fiber on darwin `clang_rt` unverified; highest-value future darwin port  |
| `valgrind-memcheck-catch.d`  | keep linux (forever)   | Valgrind dead on modern macOS                                                         |
| `valgrind-client-requests.d` | keep linux (forever)   | same                                                                                  |
| `valgrind-attribution.d`     | keep linux (forever)   | same                                                                                  |

If a darwin probe is ever wanted, the cheapest is a **new** `aarch64-darwin` variant
of `asan-heap-uaf` — `abort_on_error=0:detect_leaks=0`, `MallocNanoZone=0`,
`core.sys.posix.dlfcn`, and signal-tolerant exit checks — explicitly a new file, not
a `platforms` widening. The darwin _story_ belongs here in prose (these hand-run
transcripts), not as a CI-executed probe.

---

## What this means for sparkles

The column-by-column delta from the Linux reference model, and where each concern
lands (the capstone [comparison.md][comparison] folds these into its cross-OS
capability matrix):

| Concern                         | macOS delta vs Linux                                                    | Windows delta vs Linux                                                       |
| ------------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Defect classes                  | same ASan/TSan set; UBSan still N/A from D; **LSan status open**        | ASan only; **no TSan/LSan/MSan/UBSan/HWASan**; Dr. Memory adds handle leaks  |
| Instrumentation / recompile     | identical IR pass; **dylib-only** runtime                               | IR pass + **runtime hotpatch** (can fail→debugbreak); Dr. Memory = DBI       |
| D & druntime                    | GC blind spot unchanged; fixtures _pending hw_                          | DMD = Dr. Memory only; LDC ASan works but **#3760 exceptions**; GDC N/A      |
| Runtime control                 | `abort_on_error=1` → **exit 134**; `MallocNanoZone=0` mandatory         | **`continue_on_error`** (env, no compile flag); UAR = **compile flag**       |
| Symbolization / suppressions    | Mach-O/dSYM via `atos`; empty-dSYM foot-gun; mangled globs              | PDB + LLVM symbolizer; Dr. Memory **no D demangler**; **no ignorelist**      |
| Test-runner integration         | exit 134 ≠ 1; SIP strips `DYLD_INSERT_LIBRARIES`                        | COE app-exit semantics; Dr. Memory **preserves app exit** by default         |
| Platform / toolchain / overhead | official LDC ships `ldc_rt` dylibs; nix LDC cc-fallback; **no timings** | x86/x64 only; arm64 = **zero runtimes**; Dr. Memory coasting; **no timings** |

Three consequences for the runner's design:

1. **The CI matrix row** already runs `ci --example-files` on `macos-latest`; because
   the probes are `platforms "linux"`, that row `⊘`-skips them — correct and
   intentional. A `--sanitize` runner mode's darwin leg would have to pin the
   cc-fallback toolchain and normalize `abort_on_error`/`MallocNanoZone` per-child.
2. **Exit codes are three-way irreconcilable** off Linux (darwin 134, Windows
   COE-app-own / Dr. Memory-app-own), reinforcing the [halt-vs-recover][halt-vs-recover]
   finding that a `--sanitize` mode must **count reports, not read exit codes**.
3. **The one-liner:** the sanitizer columns end at the Linux border **except
   AddressSanitizer** — ASan crosses to both macOS (dylib, hardware-proven for C) and
   Windows (DLL, LDC-shipped but exception-limited for D); everything else is Linux
   (TSan, LSan on Windows), dead (Valgrind on macOS), or absent (arm64 on both).

---

## Sources

**LDC driver + packaging (read via `git show v1.41.0:`).**

- [`driver/linker-gcc.cpp`][ldc-linker-gcc] — `addSanitizerLinkFlags`; the Darwin
  dylib-only comment + two-rpath link + cc fallback.
- [`driver/linker-msvc.cpp`][ldc-linker-msvc] — `ldc_rt.asan.lib` + thunks; the
  `// TODO: remaining sanitizers` end.
- [`tests/sanitizers/lit.local.cfg`][ldc-lit] — Darwin `abort_on_error=1`; TSan on
  for Darwin, off for Windows.
- [`CMakeLists.txt`][ldc-cmake] + [`CHANGELOG.md`][ldc-changelog] —
  `copy_compilerrt_lib`; the Windows-LSan exclusion.
- Official release-tarball listings (downloaded, listed, deleted 2026-07-11):
  `ldc2-1.41.0-osx-universal.tar.xz`, `ldc2-1.41.0-windows-multilib.7z`.

**compiler-rt (`llvm-project` @ [`73802c2e`][llvm-src]).**

- [`compiler-rt/lib/lsan/lsan_common.h`][compiler-rt-lsan] — `CAN_SANITIZE_LEAKS` on
  arm64-darwin.
- [`compiler-rt/unittests/lit.common.unit.cfg.py`][compiler-rt-nanozone] —
  `MallocNanoZone=0` / rdar://80086125.

**Nix artifact verification (no Mac; `cache.nixos.org` NAR listings).** nixpkgs
`aarch64-darwin` LDC ships only `ldc_rt.dso.o` and dangles its `ldc2.conf`
compiler-rt dir; nixpkgs darwin `compiler-rt` 21.1.7 ships the full osx sanitizer
dylib set.

**MS Learn (MSVC, `ms.date` 2026-05-28), `[literature]`.**
[AddressSanitizer overview][msvc-asan] · [`/fsanitize`][msvc-fsanitize] ·
[runtime][msvc-asan-runtime] · [shadow bytes][msvc-asan-shadow] ·
[continue-on-error][msvc-asan-coe] · [building][msvc-asan-building] ·
[known issues][msvc-asan-known-issues] · [WinDbg TTD][windbg-ttd].

**Dr. Memory (`drmemory` @ `3d2b5f9`), `[source-verified]`.** [`README`][drmemory],
`drmemory/optionsx.h`, `docs/using.dox`, `docs/reports.dox`; [releases][drmemory-releases].

**Valgrind-on-macOS.** [platforms page][valgrind-platforms] · configure.ac hard-error
(cross-linked from [valgrind.md][valgrind-platform]) · [LouisBrunner fork][louisbrunner].

**Other.** [ldc #3760][ldc-3760] (D exceptions under Windows ASan) ·
[llvm PR #93770][llvm-pr-93770] (static ASan runtime elimination) ·
[msys2 #3163][msys-3163] (MinGW libsanitizer) · recon `mac-bsn` smoke test
(`aarch64-darwin`, 2026-07-11).

Shared vocabulary: [concepts.md][concepts] ([instrumentation locus][locus],
[interceptor][interceptor], [runtime selection][runtime-selection],
[halt vs recover][halt-vs-recover], [fake stack / UAR][fake-stack],
[suppression][suppression], [weak-hook surface][weak-hooks],
[GC blind spot][gc-blind-spot]).

> [!NOTE]
> **No runnable CI example ships with this page.** The survey's convention is a
> CI-compiled probe per deep-dive, but CI has no `aarch64-darwin` or Windows host and
> the eleven batch-1 probes are Linux-locked by design (above). The macOS mechanism
> is `[source-verified]` against LDC v1.41.0 / compiler-rt `73802c2e` / release
> artifacts, with **one** `[hw-verified: aarch64-darwin]` datum (the recon Apple-clang
> ASan smoke test); the darwin run transcripts are _pending hardware verification_
> (rerun kit staged; tracked as an open Q-row in the survey's grounding register). The
> Windows column is `[literature]` + `[source-verified]`, never `[hw-verified]`.

<!-- References -->

[concepts]: ./concepts.md
[locus]: ./concepts.md#instrumentation-locus
[runtime-selection]: ./concepts.md#sanitizer-runtime-selection
[interceptor]: ./concepts.md#interceptor
[halt-vs-recover]: ./concepts.md#halt-vs-recover
[fake-stack]: ./concepts.md#fake-stack-and-stack-use-after-return
[suppression]: ./concepts.md#suppression
[weak-hooks]: ./concepts.md#weak-hook-control-surface
[gc-blind-spot]: ./concepts.md#the-gc-memory-blind-spot
[definedness]: ./concepts.md#definedness-vs-addressability
[asan]: ./asan.md
[ubsan]: ./ubsan.md
[tsan]: ./tsan.md
[d-toolchain]: ./d-toolchain.md
[valgrind]: ./valgrind.md
[valgrind-platform]: ./valgrind.md#platform-and-toolchain-coverage
[comparison]: ./comparison.md
[cpu-pmu-macos]: ../cpu-pmu/macos.md
[llvm-src]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[ldc-linker-gcc]: https://github.com/ldc-developers/ldc/blob/90e39b6a6e61d36ef5f5d0ab6ae0667130fd8549/driver/linker-gcc.cpp
[ldc-linker-msvc]: https://github.com/ldc-developers/ldc/blob/90e39b6a6e61d36ef5f5d0ab6ae0667130fd8549/driver/linker-msvc.cpp
[ldc-lit]: https://github.com/ldc-developers/ldc/blob/90e39b6a6e61d36ef5f5d0ab6ae0667130fd8549/tests/sanitizers/lit.local.cfg
[ldc-cmake]: https://github.com/ldc-developers/ldc/blob/90e39b6a6e61d36ef5f5d0ab6ae0667130fd8549/CMakeLists.txt
[ldc-changelog]: https://github.com/ldc-developers/ldc/blob/90e39b6a6e61d36ef5f5d0ab6ae0667130fd8549/CHANGELOG.md
[ldc-3760]: https://github.com/ldc-developers/ldc/issues/3760
[compiler-rt-lsan]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/compiler-rt/lib/lsan/lsan_common.h
[compiler-rt-nanozone]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/compiler-rt/unittests/lit.common.unit.cfg.py
[msvc-asan]: https://learn.microsoft.com/en-us/cpp/sanitizers/asan
[msvc-fsanitize]: https://learn.microsoft.com/en-us/cpp/build/reference/fsanitize
[msvc-asan-runtime]: https://learn.microsoft.com/en-us/cpp/sanitizers/asan-runtime
[msvc-asan-shadow]: https://learn.microsoft.com/en-us/cpp/sanitizers/asan-shadow-bytes
[msvc-asan-coe]: https://learn.microsoft.com/en-us/cpp/sanitizers/asan-continue-on-error
[msvc-asan-building]: https://learn.microsoft.com/en-us/cpp/sanitizers/asan-building
[msvc-asan-known-issues]: https://learn.microsoft.com/en-us/cpp/sanitizers/asan-known-issues
[windbg-ttd]: https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/time-travel-debugging-overview
[drmemory]: https://github.com/DynamoRIO/drmemory
[drmemory-releases]: https://github.com/DynamoRIO/drmemory/releases
[valgrind-platforms]: https://valgrind.org/info/platforms.html
[louisbrunner]: https://github.com/LouisBrunner/valgrind-macos
[llvm-pr-93770]: https://github.com/llvm/llvm-project/pull/93770
[msys-3163]: https://github.com/msys2/MINGW-packages/issues/3163
