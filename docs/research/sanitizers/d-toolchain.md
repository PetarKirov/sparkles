# The D toolchain (LDC / GDC / DMD)

The survey's **center of gravity**: which of the three D compilers can reach a
sanitizer at all, what has to be recompiled to instrument a D program (and how
`dub` does it), and where druntime's garbage collector, fibers, and threads
collide with a tool that was designed for `malloc`/`free` C.

| Field                                                | Value                                                                                                                                                                               |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Compilers                                            | **LDC 1.41.0** (LLVM 18.1.8, DMD front-end 2.111.0) · **GDC 11.5.0** · **DMD 2.112.1**                                                                                              |
| Sanitizers reachable                                 | LDC: `address`, `leak`, `thread`, `memory`, `fuzzer` — **no UBSan** ([ubsan.md][ubsan]); GDC: `address` (with a workaround), `undefined` (check-empty for D); **DMD: none**         |
| [Instrumentation locus][locus]                       | **LLVM IR pass** (LDC) — registered at the optimizer tail, so any LLVM front-end inherits it "for free"; GCC IR pass (GDC); binary translation only (DMD, via [Valgrind][valgrind]) |
| [Runtime library][runtime-selection] actually linked | nixpkgs LDC → **GCC 15.2** `libasan.so.8` / `libtsan.so.2` (the gcc fallback); official LDC tarball → bundled `libldc_rt.*`. Both self-symbolize; **neither demangles D**           |
| druntime `SupportSanitizers`                         | Compiled into **no shipped build** — nixpkgs _and_ official tarball (nm-verified). Gates GC-root/fake-stack correctness, **not** detection.                                         |
| MSan                                                 | This page **owns** the survey's MemorySanitizer story: it does not link by default, links via a `-conf=` compiler-rt edit, and is unusable without an instrumented world            |
| Verification                                         | `[hw-verified: x86_64-linux]` — 18 recorded experiments (E1–E18); the darwin/windows link branches are `[source-verified]` here and handed to [macos-windows.md][macos-windows]     |

> [!NOTE]
> All hardware experiments were recorded on **Linux 6.18.26**, an **AMD Ryzen 9
> 7940HX** (Zen 4), against **LDC 1.41.0** (LLVM 18.1.8, front-end 2.111.0),
> **DMD 2.112.1**, **dub 1.42.0-beta.1** (commit `5efed360`), **gcc 15.2.0**
> (the `CC` used as the link driver, providing `libasan.so.8` / `libtsan.so.2`),
> and **GDC 11.5.0** (from `nixos-25.05`). Source was read against
> `dlang/ldc@v1.41.0`, `dlang/dmd@e6baf474`, and `dlang/dub@5efed360`. The two
> flagship probes — [`gc-uaf-blindspot.d`][gc-uaf-probe] and
> [`fiber-asan.d`][fiber-probe] — run on this box under LDC and `SKIP:` cleanly
> under DMD.

---

## Overview

### What it solves

A sanitizer is a compiler pass plus a runtime library plus a set of libc
[interceptors][interceptor]. For a D program to use one, three questions have to
line up: (1) does the D compiler emit the instrumentation; (2) does something
link the runtime; and (3) does D's own runtime — the garbage collector, fibers,
the signal-based thread suspension — behave under it. This page answers all
three across the three D compilers and the three ways an LDC install ships (or
fails to ship) its runtime libraries. The short version is that **LDC on Linux
is the only fully working path**, that it works today largely by accident (it
borrows GCC's sanitizer runtime through a fallback meant for Clang), and that
D's GC is a permanent blind spot no toolchain choice closes.

### Design philosophy: three compilers, three distribution channels

The reachability of a sanitizer from D is decided almost entirely upstream, by
LLVM. Because AddressSanitizer, ThreadSanitizer, and MemorySanitizer are
[LLVM IR passes][locus], LDC inherits them the moment its driver plumbs the
flag; DMD, which has its own back-end and no such pass, inherits nothing. But
the _runtime_ side is a packaging lottery. LDC's linker driver embodies this in
one fallback that turns out to carry the entire nixpkgs experience
([`driver/linker-gcc.cpp:368-371`][ldc-tree], `@v1.41.0`):

> ```cpp
> // When we reach here, we did not find the sanitizer library.
> // Fallback, requires Clang.
> args.emplace_back(fallbackFlag);
> ```

`[source-verified]` The comment says "requires Clang", but on this box the
fallback hands `-fsanitize=address` to **gcc**, and it works: gcc links its own
`libasan.so.8`. That single line is why a nixpkgs LDC that ships _zero_
compiler-rt libraries can still catch a heap-use-after-free. The official
tarballs take the opposite stance ([`docs/compiler_rt.md:9-10`][ldc-compiler-rt-doc]):

> The tarballs at https://github.com/ldc-developers/ldc/releases come with the
> compiler-rt libraries and you don't need to do any configuration.

`[source-verified]` Both statements are true, and which one you are living under
determines whether MSan links, whether reports demangle, and whether you need
`llvm-symbolizer` on `PATH`. The rest of this page is the consequences.

---

## How it works

### LDC: the flag, the pass, the link

LDC's `-fsanitize=` accepts exactly `address`, `fuzzer`, `leak`, `memory`, and
`thread` — a `StringSwitch` in
[`driver/cl_options_sanitizers.cpp:182-188`][ldc-tree]; the binary rejects
`undefined` outright. `[source-verified]` `[hw-verified: x86_64-linux]` The
sanitizer logic is **byte-identical** between `v1.41.0` and the checked-out
`v1.42.0-91` (`git diff` shows only an LLVM-version macro rename), so the LDC
findings here are not going to drift with the next point release.
`[source-verified]`

The pipeline from flag to instrumented object is three hops:

1. **Flag parse and per-function gating.** Each enabled sanitizer stamps an LLVM
   function attribute (`SanitizeAddress` / `SanitizeMemory` / `SanitizeThread`)
   onto every function ([`gen/functions.cpp:1161-1177`][ldc-tree]) unless the
   function is blacklisted or carries the druntime opt-out UDA
   `@noSanitize("address")` ([`runtime/druntime/src/ldc/attributes.d:285-293`][ldc-tree]).
   That UDA is a direct precedent for a per-test opt-out in the runner
   ([`attributes.d:286-289`][ldc-tree]):

   > Disables a particular sanitizer for this function. Valid sanitizer names
   > are all names accepted by `-fsanitize=` commandline option.

   `[source-verified]`

2. **The IR passes, at the optimizer tail.** `gen/optimizer.cpp` registers stock
   LLVM passes via `pb.registerOptimizerLastEPCallback`
   ([`:504-523`][ldc-tree]): `addAddressSanitizerPasses` ([`:213-231`][ldc-tree],
   honoring the recover bits and `-fsanitize-address-use-after-return`),
   `addMemorySanitizerPass` ([`:233-259`][ldc-tree], with
   `-fsanitize-memory-track-origins`), and `addThreadSanitizerPass`
   ([`:261-270`][ldc-tree]). Because these run on LLVM IR, LDC gets them with no
   front-end work; this is the mechanical reason DMD cannot. `[source-verified]`

3. **The runtime link.** For each enabled sanitizer LDC probes its `ldc2.conf`
   `lib-dirs` for `libldc_rt.<san>.a` → `libclang_rt.<san>-<arch>.a` →
   `libclang_rt.<san>.a` (`getFullCompilerRTLibPathCandidates`,
   [`driver/linker-gcc.cpp:306-330`][ldc-tree]); the first hit is passed as an
   object path. If none is found, the fallback quote above appends the plain
   `-fsanitize=<kind>` flag for the C-compiler link driver. `[source-verified]`

Two more flags matter downstream. `-fsanitize-recover=` accepts only `address`
and `memory` (`supportedSanitizerRecoveries`,
[`cl_options_sanitizers.cpp:176`][ldc-tree]) — there is **no** recover mode for
thread or leak, so a TSan or LSan finding cannot be made non-fatal at compile
time. `[source-verified]` And `-fsanitize-blacklist=<file>` accepts compiler-rt's
`SpecialCaseList` format, but LDC consults only the empty (global) section:
`fun:` entries match the **mangled** D name, `src:` entries match the filename,
and per-sanitizer sections like `[address]` are silently ignored (an explicit
TODO, [`:223-229`][ldc-tree], [`:247-259`][ldc-tree]). Experiment 7 confirmed
both `fun:_D6gc_uaf18mallocUseAfterFreeFZv` (mangled) and `src:*gc-uaf.d` turn
an otherwise-caught heap-UAF into a clean exit 0. `[hw-verified: x86_64-linux]`

Compiling with `-fsanitize=address` or `thread` predefines the version
identifiers `LDC_AddressSanitizer` / `LDC_ThreadSanitizer` — the compile-time
gate both flagship probes use to decide whether they were built instrumented at
all. `[hw-verified: x86_64-linux]`

### The three runtime-distribution realities

An IR-instrumented object is inert until it links a [runtime][runtime-selection].
Which one it gets — if any — is the packaging lottery, and there are exactly
three outcomes on this box:

| Distribution                    | Ships compiler-rt?       | What links                                | Symbolization                                          | MSan           |
| ------------------------------- | ------------------------ | ----------------------------------------- | ------------------------------------------------------ | -------------- |
| **nixpkgs LDC** (this box)      | No — dead conf `lib-dir` | GCC 15.2 `libasan`/`libtsan` via fallback | Self-symbolizes (`libbacktrace`), no `llvm-symbolizer` | **Link-fails** |
| **Official LDC tarball**        | Yes — full `libldc_rt.*` | Bundled static `clang_rt`                 | Needs `llvm-symbolizer` for `file:line`                | Links          |
| **nixpkgs LDC + `-conf=` edit** | Realized `compiler-rt`   | Static `libclang_rt.<san>-x86_64.a`       | Needs `ASAN_SYMBOLIZER_PATH`; demangles `D main`       | Links & runs   |

The nixpkgs reality is a _dead store path_: `LDC_INSTALL_LLVM_RUNTIME_LIBS`
defaults OFF when LLVM is shared ([`CMakeLists.txt:849-855`][ldc-tree]), which
nixpkgs always is, so the generated `ldc2.conf` records only a
`COMPILER_RT_LIBDIR` that contains nothing ([`:922-931`][ldc-tree]). ASan, LSan,
and TSan then work solely through the gcc fallback → GCC 15.2's runtimes, which
**self-symbolize to full D `file:line` with no `llvm-symbolizer`** but never
demangle D names. `[hw-verified: x86_64-linux]` `[source-verified]`

The official tarball ships `lib/libldc_rt.{asan,lsan,tsan,msan,fuzzer,…}.a`
(Experiment 15, `tar -tf` inventory) — MSan is linkable out of the box there.
`[hw-verified: x86_64-linux]` And the nixpkgs install can be _made_ to link real
`clang_rt` with a one-line conf edit: realize `nixpkgs#llvmPackages_18.compiler-rt`
(whose `lib/linux/libclang_rt.<san>-x86_64.a` layout matches LDC's second
candidate name) and point an edited **copy** of `ldc2.conf`, passed via
`-conf=`, at it. LDC's runtime search iterates only `ldc2.conf` `lib-dirs`, _not_
`-L` flags, so the conf copy is the lever, not a link-line flag. ASan then links
the static `libclang_rt.asan-x86_64.a` explicitly and drops `-fsanitize=address`
from the gcc line entirely (Experiment 8); reports are **unsymbolized** until
`ASAN_SYMBOLIZER_PATH` points at an `llvm-symbolizer` (21.1.7 works against the
18.1.8 runtime, then demangles to `D main` and adds column numbers).
`[hw-verified: x86_64-linux]`

> [!NOTE]
> **The plain-`ld` path is silently unplumbed.** LDC's non-gcc linker driver
> (`LdArgsBuilder`) overrides `addSanitizers` with an **empty body**
> ([`driver/linker-gcc.cpp:764-766`][ldc-tree]: `void addSanitizers(const
llvm::Triple &triple) override {}`). A build that drives `ld` directly links
> _no_ sanitizer runtime and no fallback flag — the instrumented object is inert
> with no error. The sparkles unittest configs use `gold`, not bare `ld`, so
> this does not bite in practice; recorded as `[source-verified]`, `◯` untested.

### Building an instrumented world: `ldc-build-runtime`

For MSan (and for correct fiber GC-roots — see concern 3), the shipped druntime
is not enough; you need one built with instrumentation. The shipped
`ldc-build-runtime` tool does it on this box in **~3 minutes**:

```bash
# cmake + ninja come from `nix shell`; the source auto-download is broken on
# NixOS (std.net.curl can't dlopen libcurl), so fetch the source archive by hand
nix shell nixpkgs#cmake nixpkgs#ninja -c \
  ldc-build-runtime --ninja --buildDir=./bd \
    --dFlags="-fsanitize=address" RT_SUPPORT_SANITIZERS=ON BUILD_SHARED_LIBS=OFF
# → [52/52] Linking D static library lib/libphobos2-ldc.a  (~3 min)
```

The result carries both the instrumentation and the fiber hooks
(`nm bd/lib/libdruntime-ldc.a | grep -c asan` → 4196;
`informSanitizerOfStartSwitchFiber` present, `__sanitizer_start_switch_fiber`
resolving as a weak `w` symbol). Link user code against it with `-L-L$PWD/bd/lib`
(user `-L` flags precede conf `lib-dirs`). Two frictions worth recording: the
auto-download of the source archive dies with
`std.net.curl.CurlException…Failed to load curl` — the same libcurl-on-NixOS
problem the repo has hit before — so the source zip must be fetched by hand; and
cmake/ninja come from `nix shell`, not the devshell. `[hw-verified: x86_64-linux]`

---

## The seven concerns

The concern order is fixed across the survey. None is fully N/A here — the D
toolchain touches all seven — but many findings are _absences with a locator_
(LDC has no UBSan mode; DMD has no sanitizer switch; no shipped druntime enables
`SupportSanitizers`), and each absence is stated as a finding, not a blank.

### Defect classes and per-compiler reach

**Concern 1 — the reachability map.** What each compiler can catch:

| Compiler     | ASan                             | LSan                   | TSan             | MSan                              | UBSan                                        |
| ------------ | -------------------------------- | ---------------------- | ---------------- | --------------------------------- | -------------------------------------------- |
| **LDC**      | ✅ (fallback rt)                 | ✅ (bundled with ASan) | ✅ (fallback rt) | ⚠️ link-fails; ✅ via `-conf=` rt | ❌ **no `-fsanitize=undefined` mode**        |
| **GDC 11.5** | ✅ with `--param asan-globals=0` | ✅ (liblsan)           | ✅ (libtsan)     | (untested)                        | ⚠️ links but **emits no D checks**           |
| **DMD**      | ❌ **no sanitizer flag at all**  | ❌                     | ❌               | ❌                                | ❌ → [Valgrind][valgrind] is DMD's only path |

The single most important D-specific _miss_ cuts across every memory tool: a
**use-after-free inside GC memory is invisible** to ASan, LSan, `memcheck`,
HWASan, and GWP-ASan alike, because GC pools never pass through a sanitizer's
[allocator interceptor][allocator-interception]. That is [the GC memory blind
spot][gc-blind-spot], the headline finding of concern 3, and it is architectural
— no compiler choice closes it.

**GDC is not dead for ASan.** Recon's `cannot find -lasan` was a _packaging_ gap,
not a compiler gap. Pointing GDC at gcc11's own artifacts makes ASan link:

```bash
gdc -fsanitize=address -g x.d -o x \
    -B/nix/store/…-gcc-11.5.0/lib -L/nix/store/…-gcc-11.5.0-lib/lib
```

But the resulting binary **SEGVs in druntime init** — ASan's global-variable
redzones break GDC druntime's `ModuleInfo` section walk during `sortCtors`
(`#0 …ModuleInfo.flags → #2 rt.minfo.ModuleGroup.sortCtors`). Adding
**`--param asan-globals=0`** disables the global redzones and yields a fully
working ASan: heap-UAF caught, `file:line`, exit 1 (Experiment 16). The
`asan-globals` ↔ `ModuleInfo`-walk conflict is a genuinely new, documentable
D-specific footgun. `[hw-verified: x86_64-linux]`

**DMD reaches nothing.** `compiler/src/dmd/cli.d` @ `e6baf474` contains 120
`Option(` entries and **zero** matches for "sanitize"; the binary answers
`dmd -fsanitize=address` with `Error: unrecognized switch`. DMD's only
sanitizer-family path is [Valgrind][valgrind], which recompiles nothing.
`[source-verified]` `[hw-verified: x86_64-linux]`

GCC's documented `-fsanitize` set (the GDC column's upstream reference) is
`address`, `hwaddress`, `kernel-address`, `pointer-compare`, `pointer-subtract`,
`thread`, `leak`, `undefined` (plus ~20 UBSan sub-checks) and `shadow-call-stack`
— saved as `gcc-15.1-instrumentation-options.html`. `[literature]`

### Instrumentation model: what must be recompiled, and how

**Concern 2 — the dub channels.** ASan and TSan need only _user_ code
instrumented to catch a bug in user code; instrumenting more buys coverage of
more frames, not correctness (MSan is the exception — see [its section
below](#msan-the-instrumented-world-requirement) and the
[instrumented-world requirement][instrumented-world]). `-betterC` programs need
nothing extra at all. The interesting engineering is how `dub` propagates the
flag across a package closure — and one trap that silently validates nothing.

> [!WARNING]
> **`DFLAGS=… dub test` is a silent false green.** When `DFLAGS` is set and no
> `-b` is given, dub sets the build type to the magic `"$DFLAGS"`
> ([`commandline.d:1381`][dub-tree]), which contributes **no build options**
> ([`package_.d:426`][dub-tree]: `case "$DFLAGS": break;`). For `dub test` that
> drops `unittests` → **no `-unittest` anywhere** → the sparkles shim compiles
> to an empty module (`register.d:13` is `version (unittest):`), druntime finds
> zero tests, and dub prints "All unit tests have been run successfully."
> ([`project.d:2150-2158`][dub-tree]), exit 0. Experiment 2:
> `DFLAGS="-fsanitize=address" dub test :versions` compiled **0** lines with
> `-unittest`, ran **0** tests, exited 0, and _did_ link `libasan` (`ldd`
> confirms) — a build that looks sanitized and tested and is neither. The
> documented root ([`commandline.d:1294`][dub-tree]):
> "Note that setting the DFLAGS environment variable will override the build
> type with custom flags." The fix is `dub test -b unittest`; Experiment 3 then
> ran 167 tests under ASan. `[hw-verified: x86_64-linux]` `[source-verified]`
> This is the same command the repo's `feat/event-horizon` history recorded as
> its ASan/TSan recipe — see the historical-recipe walk in
> [sparkles-baseline.md][baseline].

With `-b` supplied there are three sound channels, all verified to reach the
whole closure:

1. **`-b unittest` + `DFLAGS`.** DFLAGS are appended _last_, per package, across
   the whole closure ([`package_.d:444-445`][dub-tree]: "Add environment DFLAGS
   last so that user specified values are not overriden by us"). 167 tests ran
   ASan-clean (Experiment 3). `[hw-verified: x86_64-linux]`
2. **A custom `buildType`.** A `buildType "asan" { buildOptions "unittests"
"debugMode" "debugInfo" dflags "-fsanitize=address" }` applies to **every**
   target ([`generator.d:775-788`][dub-tree]), with `unittests` stripped from
   non-root packages ([`project.d:978-993`][dub-tree], issue #640). `dub test -b
asan :versions` rebuilt all 5 packages _including the registry dependency_
   `expected` and ran 167 tests (Experiment 4a). Caveat: buildTypes are read
   from the **root package of the build** ([`package_.d:418-427`][dub-tree]), so
   each tested sub-package needs the recipe in _its_ `dub.sdl`. This repo already
   uses `dub test -b <name>` as a documented flag-injection channel.
   `[hw-verified: x86_64-linux]`
3. **A per-package `dflags "-fsanitize=address"`.** New in dub 1.42.0-beta.1
   (PR #3111, Apr 2026), `-fsanitize=` is treated as **ABI-critical** and
   propagates in _both_ directions across the dependency graph. `dub`'s own words
   ([`compilers/buildsettings.d:671-672`][dub-tree]):

   > ```d
   > // LDC – sanitizer instrumentation must be consistent
   > "-fsanitize=",
   > ```

   `filterABICriticalFlags` ([`buildsettings.d:660-677`][dub-tree]) feeds
   `mergeFromDependent` (dependent→dependency, [`generator.d:741-750`][dub-tree])
   while `mergeFromDependency` has always pushed all dflags the other way
   ([`:752-757`][dub-tree]). The flag on **leaf** `base` reached `core-cli`,
   `test-runner-impl`, `versions`, _and_ `expected` (Experiments 4b/4c).
   `[hw-verified: x86_64-linux]` `[source-verified]`

The load-bearing consequence of #3: **mixed instrumentation can no longer arise
through dub channels** on a current dub. On **older dubs** (before Apr 2026) only
the upward direction existed, so the prebuilt `test-runner-impl` would stay
uninstrumented if only the consumer's config carried the flag — a silent gap, not
a link error. Forced manually (Experiment 6, a two-object link), mixed
instrumentation links and runs fine but _misses_ a use-after-free whose faulting
load is in uninstrumented code (exit 0, garbage read); the allocator interception
is process-wide, so uninstrumented code that allocates through ASan's `malloc` is
still protected wherever _instrumented_ code touches it. `[hw-verified: x86_64-linux]`

Two more mechanics: the build ID hashes `buildsettings.dflags`
([`generator.d:851-876`][dub-tree]), so sanitized and plain builds get separate
cache slots and **`--force` is unnecessary** (the event-horizon recipe's
`--force` was superfluous). `[hw-verified: x86_64-linux]` And `-checkaction=context`
(which the sparkles unittest configs force) coexists with `-fsanitize=address` on
every sanitized compile line — 167 + 278 tests passed with both present.
`[hw-verified: x86_64-linux]` The one unresolved item is `-allinst`: no
sanitizer-specific failure was reproducible with or without it (Experiment 5b),
so the event-horizon "-allinst fix" note is either package-specific or an
artifact of the older setup; its necessity for the seed package (which lives only
on `feat/event-horizon`) remains unconfirmed. `◯`

### D and druntime interaction

**Concern 3 — the core of this page.** This is where D departs from the C model
the tools assume. Four findings, one flagship.

#### The GC blind spot: ASan cannot see GC pools

D's garbage collector obtains its pools with `mmap`, not `malloc`: the allocator
chain is `VirtualAlloc` → `mmap` → `malloc` (`core/internal/gc/os.d:111-117`),
and `os_mem_map` calls `mmap(null, nbytes, PROT_READ|PROT_WRITE,
MAP_PRIVATE|MAP_ANON, -1, 0)` (`os.d:176-196`). GC memory therefore sits
_outside_ every sanitizer allocator, and a freed GC block is never poisoned in
any shadow a tool owns. The flagship probe
[`gc-uaf-blindspot.d`][gc-uaf-probe] proves the contrast as a self-verifying
pair: a `GC.malloc` → `GC.free` → read runs to completion with **no report**
(exit 0), while the identical bug on `core.stdc.stdlib.malloc`/`free` dies with
`heap-use-after-free`, a symbolized `file:line`, and exit 1. Crucially, this
holds **even against a fully ASan-instrumented druntime** (Experiment 13,
against the `ldc-build-runtime` build) — the blind spot is architectural, not a
missing-instrumentation artifact. `[hw-verified: x86_64-linux]` `[source-verified]`

The LSan half of the same blind spot is a _false positive_ rather than a false
negative: a `malloc` block reachable only through a pointer stored in GC memory
is reported as a leak, because LSan's [root scan][stw-root-scan] terminates when
a pointer lands inside a GC pool. The `memcheck` half — but _only_ the `memcheck`
half — is closable without rebuilding druntime (see [`etc.valgrind`](#tls-roots-and-etc-valgrind) below). Full LSan/GC treatment is [asan.md][asan]'s.

#### Fibers under ASan: fake stacks and stack-use-after-return

Fiber stacks are `mmap(PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON)` plus an
`mprotect` guard page (`core/thread/fiber/package.d:650-760`, default
`guardPageSize = pageSize`). Under ASan's [fake-stack][fake-stack] mode, an
address-taken local escaping its frame is caught when the escaped pointer is
later read — and that is exactly the bug shape the probe
[`fiber-asan.d`][fiber-probe] reproduces (the `feat/event-horizon` `c9537f96`
defect: a `scope` delegate stored for deferred `Fiber.call`). With
`ASAN_OPTIONS=detect_stack_use_after_return=1`, the deferred fiber's call through
the dead closure dies with `stack-use-after-return` symbolized to the closure
body, exit 1; with `=0` the same run reads garbage and exits 0.
`[hw-verified: x86_64-linux]`

The finding that matters for the runner: **this catch works against the stock,
no-`SupportSanitizers` druntime** — no fiber annotations are required for this
defect, because the faulting read happens in _instrumented user code_, not inside
a druntime handoff. (GCC 15's `libasan` even defaults
`detect_stack_use_after_return` ON, so it catches with empty `ASAN_OPTIONS`;
under real `clang_rt` on Linux the option is off by default, so the probe sets it
explicitly for determinism.) `[hw-verified: x86_64-linux]`

#### `SupportSanitizers`: shipped nowhere, needed only for GC-root correctness

The LDC fork carries real fiber support in source — fiber-switch hooks
`informSanitizerOfStartSwitchFiber`/`FinishSwitchFiber` around every context
switch (`core/thread/fiber/base.d:797-889`), per-fiber `__fake_stack`
bookkeeping (`:911`), and GC scanning of fake frames via
`scanStackForASanFakeStack` (`threadbase.d:1141`, body `:1160-1208`) — all under
`version (SupportSanitizers)`, which is enabled only by the CMake option
`RT_SUPPORT_SANITIZERS` (default OFF, `runtime/CMakeLists.txt:49`). The
weak-linking trick in `ldc/sanitizers_optionally_linked.d`
(`pragma(LDC_extern_weak)` forward declarations, resolved once and cached) lets
one druntime binary work with _or_ without a sanitizer runtime present.
`[source-verified]`

But **no shipped druntime enables it.** `nm` on the nixpkgs
`libdruntime-ldc.a` shows `sanitizers_optionally_linked.o` carries only
`__ModuleInfo` symbols; the official `ldc2-1.41.0-linux-x86_64` tarball's
`libdruntime-ldc.a` has **zero** `informSanitizerOfStartSwitchFiber` matches
(Experiment 15). The release workflow never passes `RT_SUPPORT_SANITIZERS` — only
the LLVM-version CI matrix does. So the fiber-ASan machinery is effectively
build-it-yourself, and its purpose is narrow: **fiber identity in reports,
correctness under runtime-internal handoffs, and GC scanning of fake stacks** —
_not_ the basic stack-use-after-return detection above, which works without it.
`[hw-verified: x86_64-linux]` `[source-verified]` (For the fiber-annotation API
as a cross-tool concept, see [fiber annotation][fiber-annotation] and
[tsan.md][tsan].)

> [!WARNING]
> **The premature-collection hazard (open).** With UAR mode on and a druntime
> _without_ `scanStackForASanFakeStack`, address-taken locals live in ASan fake
> frames the GC never scans, so a reference held _only_ there could be
> prematurely collected. The druntime source states this is precisely why the
> function exists ([`threadbase.d:1167-1169`][ldc-tree]):
>
> > When ASan fakestack is enabled (when Use After Return detection is enabled),
> > function-local variables are stored on the heap, instead of on the regular
> > stack. This means that, without this function, GC scanning would not scan
> > function-local variables.
>
> This was **not reproduced empirically** in four attempts (objects survived;
> conservative register scanning and LLVM's choice not to fake-stack the test
> frames masked it). Recorded honestly as `[source-verified]`, reproduction `◯`
> **open** — a real but unproven hazard.

#### TLS roots and `etc.valgrind`

Per-thread GC roots are scanned by `rt_tlsgc_scan` in `scanAllTypeImpl`
(`threadbase.d:1132-1165`), with the LDC fork adding the fake-stack scan at
`:1141`. `[source-verified]` Separately, druntime ships an in-band Valgrind
annotation layer, `etc.valgrind` (`druntime/src/etc/valgrind/valgrind.d`, 85
lines), wrapping seven `memcheck` [client requests][client-request]
(`makeMemNoAccess`, `makeMemUndefined`, `makeMemDefined`, `getVBits`/`setVBits`,
the addr-reporting toggles, `:61-83`), with GC hook sites at `gc.d:616`, `:2511`,
`:3907`, and others. This is the mechanism that closes the `memcheck` half of the
GC blind spot **without a druntime rebuild** — compile the shipped `gc.d` plus
`valgrind.d` with `-debug=VALGRIND` — but the API surface, the mixed
`debug (VALGRIND)` vs `version (VALGRIND)` gating (one hook is dead code), and
the shared-libphobos link caveat all belong to [valgrind.md][valgrind].

#### `-betterC`: fully sanitizable

With no druntime in play, sanitizers work completely: `ldc2 -betterC
-fsanitize=address` catches heap-UAF and stack-UAR (exit 1, symbolized), and
`-betterC -fsanitize=thread` catches a pthread data race (exit 66)
(Experiments 5a, 14). The load-bearing consequence for the runner: **its
extract-and-recompile `--better-c` mode could sanitize betterC tests today** with
no druntime concerns at all — the cleanest sanitizer target in the whole survey.
`[hw-verified: x86_64-linux]` (Cross-link: the extract-and-recompile machinery is
[sparkles-baseline.md][baseline]'s `--better-c`/`--wasm` drivers.)

#### The tool-by-workload matrix

Pulling the concern-3 findings together — what each tool does against each of
the four workload shapes the runner actually runs (Experiments 1, 5, 8, 13, 14):

| Tool  | Plain D                                                    | GC-heavy                                                               | Fibers                                   | `-betterC`                      |
| ----- | ---------------------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------- | ------------------------------- |
| ASan  | ✅ heap-UAF caught, exit 1                                 | ✅ clean; GC-UAF **missed** (blind spot)                               | ✅ benign clean; stack-UAR caught        | ✅ heap-UAF + stack-UAR caught  |
| TSan  | ✅ race caught, exit 66; atomics clean                     | ✅ single-threaded clean; multithreaded **livelock** ([tsan.md][tsan]) | ✅ benign ping-pong clean (no fiber API) | ✅ pthread race caught, exit 66 |
| MSan  | ⚠️ link-fails default; via `-conf=` catches true positives | ❌ fresh GC `mmap` reads _defined_ → **false negative**                | (link path only)                         | (link path only)                |
| UBSan | ❌ **N/A** on LDC (no mode)                                | ❌ N/A                                                                 | ❌ N/A                                   | ❌ N/A                          |

All ASan/TSan cells are `[hw-verified: x86_64-linux]`; the MSan cells are
`[hw-verified: x86_64-linux]` via the `-conf=` route; the UBSan row is a
structural absence (LDC has no `-fsanitize=undefined`, [ubsan.md][ubsan]). The
multithreaded-TSan livelock and its [stop-the-world root scanning][stw-root-scan]
cause are [tsan.md][tsan]'s to detail.

### Runtime control and report capture

**Concern 4 — steering the tool from D.** The runner-facing seam is the set of
weak hooks and env options a program can define; the full inventory is
[the weak-hook control surface][weak-hook] and [asan.md][asan]/[tsan.md][tsan].
The toolchain-specific facts:

- **`ASAN_OPTIONS` defaults diverge by runtime.** GCC 15's `libasan` defaults
  `detect_stack_use_after_return` **ON**; `clang_rt` on Linux defaults it **off**.
  A `--sanitize` mode that depends on UAR detection must set it explicitly rather
  than trust the default. `[hw-verified: x86_64-linux]`
- **The LSan default trap.** Plain ASan enables leak checking at exit, and on
  `dub test -b unittest :base` (278 tests pass) the process then **exits 1** with
  a `LeakSanitizer` "Direct leak of 4224 byte(s)" pointing at
  `defaultTraceHandler` — druntime mallocs `Throwable` trace-info for every
  caught test exception and never frees it, and GC pools being invisible to LSan
  will add more of this class. `ASAN_OPTIONS=detect_leaks=0` → exit 0
  (Experiment 5c). **A `--sanitize=address` mode must default `detect_leaks=0`**
  or ship an LSan suppression file. `[hw-verified: x86_64-linux]`
- **Recover is address/memory only.** `-fsanitize-recover=` cannot make a TSan or
  LSan finding non-fatal at compile time (`cl_options_sanitizers.cpp:176`); TSan
  is report-and-continue by default anyway, but ASan needs _both_
  `-fsanitize-recover=address` and `halt_on_error=0` to survive a finding — and a
  recovered ASan run **exits 0**, so report capture must count reports, not read
  exit codes ([halt vs recover][halt-vs-recover]). `[source-verified]`
- **`--export-dynamic` is what makes the weak hooks fire.** The sparkles
  unittest configs already pass `lflags "--export-dynamic"` on `linux-ldc`, which
  exports the executable's dynamic symbols so the runtime finds
  `__asan_default_options`, `__tsan_on_report`, and friends. Without it the
  [weak-hook surface][weak-hook] is dark. This coexists with
  `--link-defaultlib-shared` + `gold` + a shared `libphobos2` and `libasan`
  (167/278 tests pass; both static- and shared-druntime link modes work).
  `[hw-verified: x86_64-linux]`

### Symbolization and report quality

**Concern 5 — what a report reads like.** The two runtimes diverge sharply, and
neither demangles D:

- **GCC 15 runtime** self-symbolizes to full `file:line` via bundled
  `libbacktrace` — **no `llvm-symbolizer` needed** — but prints **mangled** D
  frames (`_Dmain`, `_D6gc_uaf…` verbatim). `[hw-verified: x86_64-linux]`
- **`clang_rt`** (official tarball or `-conf=` route) needs
  `ASAN_SYMBOLIZER_PATH`/`llvm-symbolizer` for `file:line:column`, and then
  demangles the entry point to `D main` — but deeper D mangles remain mangled.
  `[hw-verified: x86_64-linux]`

So under either runtime, **proper D symbol names need `ddemangle`
post-processing**, and — the same consequence — a `-fsanitize-blacklist` or a
compiler-rt [suppression][suppression] must be written against **mangled** text
(`fun:_D…`), matching what the runtime actually prints. `[hw-verified: x86_64-linux]`

### Test-runner integration semantics

**Concern 6 — what the experiments imply for a `--sanitize` mode.** The
runner-facing conclusions, each grounded above:

- **Never `DFLAGS=… dub test`** — use `-b unittest` or a custom buildType, or the
  suite silently doesn't run (concern 2's false-green warning).
- **Default `detect_leaks=0`** (or a curated LSan suppression file) or every
  green run exits 1 on `defaultTraceHandler` (concern 4).
- **Count reports, don't trust exit codes** — recovered ASan exits 0; TSan flips
  the exit only at finalize; the tools disagree ([halt vs recover][halt-vs-recover]).
- **`@noSanitize("address")` and `-fsanitize-blacklist` are per-test opt-outs**
  already in the language (concern 1), the blacklist keyed on mangled names.
- **The in-process parallel suite is sanitizer-clean** — 167 (`versions`) and 278
  (`base`) tests ran ASan-clean through the runner's `TaskPool`, GC, and regex
  machinery (Experiments 3–5). The multithreaded-TSan livelock and the SEGV
  containment gap are [tsan.md][tsan]/[runner-integrations.md][runner-integrations]
  territory; the `--sanitize` design that ties this together is
  [integration-proposal.md][proposal].

### Platform and toolchain coverage

**Concern 7 — the full grid.** Combining compiler, sanitizer, and distribution
channel, with verification tags:

| Sanitizer | LDC (nixpkgs)                     | LDC (official tarball) | GDC 11.5              | DMD | Windows (LDC)               | Darwin (LDC)                 |
| --------- | --------------------------------- | ---------------------- | --------------------- | --- | --------------------------- | ---------------------------- |
| ASan      | ✅ gcc-rt `[hw]`                  | ✅ bundled `[hw]`      | ✅ `--param` `[hw]`   | ❌  | `ldc_rt.asan.lib` `[src]`   | `_osx_dynamic.dylib` `[src]` |
| LSan      | ✅ (with ASan) `[hw]`             | ✅ `[hw]`              | ✅ `[hw]`             | ❌  | `ldc_rt.lsan.lib` `[src]`   | `[src]`                      |
| TSan      | ✅ gcc-rt `[hw]`                  | ✅ bundled `[hw]`      | ✅ `[hw]`             | ❌  | ❌ **no link path** `[src]` | `[src]`                      |
| MSan      | ❌ link-fails; ✅ `-conf=` `[hw]` | ✅ bundled `[hw]`      | (untested)            | ❌  | ❌ **no link path** `[src]` | `[src]`                      |
| UBSan     | ❌ no mode `[hw]`                 | ❌ no mode `[hw]`      | ⚠️ check-empty `[hw]` | ❌  | ❌                          | ❌                           |

Windows and Darwin link branches are `[source-verified]` here and handed to
[macos-windows.md][macos-windows] for hardware verdicts: the LDC Windows path
links `ldc_rt.asan.lib`/`ldc_rt.lsan.lib`/`ldc_rt.fuzzer.lib` but has a comment
"TODO: remaining sanitizers" — **no TSan or MSan link path on Windows at all**
(`driver/linker-msvc.cpp:76-98`); the Darwin path links the shared
`libclang_rt.<san>_osx_dynamic.dylib` with `-rpath @executable_path`
(`driver/linker-gcc.cpp:334-366`). `[source-verified]` GDC coverage is bounded by
the note below.

> [!NOTE]
> **GDC is a moving, receding target.** The ASan and check-empty-UBSan findings
> are against GDC **11.5.0** (from `nixos-25.05`). Newer GDCs are unverified, and
> **current nixpkgs removed gdc entirely** (2025-08-08), so the GDC column is a
> snapshot of one old version, not a living platform.

---

## MSan: the instrumented-world requirement

MemorySanitizer has no page of its own in this survey; this is it. MSan tracks
[definedness][definedness] — _was this value initialized_ — by keeping a
bit-exact 1:1 [shadow][shadow] (`MEM_TO_SHADOW(mem) = mem ^ 0x500000000000`,
`lib/msan/msan.h:105-121`) and **propagating** poison through compiled code. That
propagation model is its defining constraint, the
[instrumented-world requirement][instrumented-world]
(`clang/docs/MemorySanitizer.rst:237-244`):

> MemorySanitizer requires that all program code is instrumented … including any
> libraries … even libc.

`[source-verified]` An uninstrumented function that writes a value leaves stale
poison behind, which surfaces later as a false "use of uninitialized value". For
D this plays out in three stages:

1. **It does not even link by default.** On the nixpkgs path,
   `ldc2 -fsanitize=memory …` fails at the link with
   `gcc: error: unrecognized argument to '-fsanitize=' option: 'memory'`
   (Experiment 9, verbatim) — the gcc fallback hands `-fsanitize=memory` to gcc,
   and **GCC has no MSan**. This is the honest headline finding: _MSan is a
   compile-time-only capability in LDC until you give it a real runtime._ The
   flag plumbing all exists (LDC even predefines `LDC_MemorySanitizer`,
   `driver/main.cpp:1037`, and supports `-fsanitize-recover=memory`); the runtime
   artifact is the blocker. `[hw-verified: x86_64-linux]` `[source-verified]`

2. **The `-conf=` route makes it link and run.** The same
   [compiler-rt conf edit](#the-three-runtime-distribution-realities) that
   restores `clang_rt` provides `libclang_rt.msan-x86_64.a`. MSan then links, and
   it catches a _genuine_ uninitialized read — an `int[4] arr = void` branched on
   → exit 1 (Experiment 10). `[hw-verified: x86_64-linux]`

3. **The uninstrumented world manifests as false positives, not a crash.** In a
   100%-correct two-object program where an **uninstrumented** callee writes a
   value into an instrumented caller's stack, MSan reports a false
   use-of-uninitialized-value (Experiment 10). And fresh `mmap`'d GC memory reads
   as _defined_ (no false positive from `new int[](4)`) — which also means MSan
   cannot track uninitialized GC memory, so the GC blind spot reappears here as
   false **negatives**. `[hw-verified: x86_64-linux]`

The prompt's hypothesis — "MSan likely unusable without an instrumented
druntime+Phobos" — is half-right in an unexpected way: the _default_-path problem
is that it never links (gcc fallback), not that it crashes; once linked it runs
and even finds true positives in trivial code. A genuinely useful MSan world
needs all of: an instrumented druntime+Phobos (buildable via `ldc-build-runtime
--dFlags=-fsanitize=memory`), instrumented builds of every D dependency
(automatic via dub's ABI-critical propagation, concern 2), and recompiled C
dependencies — libc itself is handled by MSan's own interceptors. That is a real
project, but it is a **finding with a locator, not a TODO**. The
[comparison.md][comparison] MSan column points here.

---

## Strengths

- **LDC on Linux is a fully working ASan/LSan/TSan path today** — flag, IR pass,
  and a runtime (GCC's, via the fallback) that self-symbolizes to `file:line`
  with no extra tooling.
- **`dub` now propagates `-fsanitize=` as ABI-critical in both directions**, so a
  single flag instruments the whole closure and mixed instrumentation cannot
  arise through dub on a current release.
- **The fiber stack-use-after-return catch works out of the box** against stock
  druntime — the flagship bug the runner most wants to catch needs no special
  build.
- **`-betterC` sanitizes perfectly**, giving the runner's extract-and-recompile
  mode a zero-friction sanitizer target.
- **A fully instrumented druntime+Phobos is buildable in ~3 minutes** with the
  shipped `ldc-build-runtime`, unblocking MSan and correct fiber GC-roots.
- **Per-function `@noSanitize` and a mangled-name blacklist** give ready-made
  per-test opt-out surfaces.

## Weaknesses

- **The GC memory blind spot is architectural** — no compiler or runtime choice
  makes a GC use-after-free visible to ASan, and GC-referenced `malloc` blocks
  are LSan false positives.
- **No shipped druntime enables `SupportSanitizers`**, so fiber GC-root
  correctness (and the premature-collection hazard) is only as good as a
  build-it-yourself runtime.
- **MSan does not link on the default nixpkgs path** and is unusable without an
  instrumented world even when it does.
- **UBSan is unreachable from D** — LDC has no mode, GDC emits no D checks, DMD
  has nothing ([ubsan.md][ubsan]).
- **DMD reaches no sanitizer at all**; its only path is out-of-process
  [Valgrind][valgrind].
- **Reports never demangle D** without `ddemangle` post-processing, and the
  `DFLAGS=… dub test` false green can make a whole sanitizer run validate
  nothing.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                      | Trade-off                                                                                       |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| LDC borrows GCC's runtime via the "requires Clang" fallback       | A runtimeless install still catches bugs, self-symbolized, with no extra tools | MSan can't link (GCC has no MSan); reports never demangle; behavior is a packaging accident     |
| Sanitizer support is `version (SupportSanitizers)`, default OFF   | One druntime binary works with or without a sanitizer runtime (weak links)     | No shipped build enables it → fiber GC-roots need a hand-built runtime; a real, unproven hazard |
| `dub` marks `-fsanitize=` ABI-critical, propagated both ways      | Instrumentation stays consistent across the closure; mixed builds can't arise  | Only on dub ≥ 1.42.0-beta.1; older dubs leave prebuilt deps uninstrumented (silent gap)         |
| `DFLAGS` overrides the build type with a no-option `$DFLAGS` type | Lets env DFLAGS augment any build without a recipe change                      | `DFLAGS=… dub test` silently drops `-unittest` → a false green that validates nothing           |
| GC pools come from `mmap`, not the intercepted `malloc`           | The GC owns its own memory layout and can move/compact                         | Every allocator-interceptor tool is blind to GC memory — the survey's defining D limitation     |

---

## Sources

- `dlang/ldc` @ `v1.41.0` ([source tree][ldc-tree]) — `driver/cl_options_sanitizers.cpp` (flag set, recover, blacklist), `driver/linker-gcc.cpp` (runtime search + fallback + Darwin branch + empty `ld` path), `driver/linker-msvc.cpp` (Windows), `gen/optimizer.cpp` / `gen/functions.cpp` (IR passes + per-function gating), `CMakeLists.txt` / `runtime/CMakeLists.txt` (why nixpkgs ships no runtime; `RT_SUPPORT_SANITIZERS`), `runtime/druntime/src/ldc/{attributes.d,sanitizers_optionally_linked.d}`, `runtime/druntime/src/core/thread/{fiber/base.d,threadbase.d}`, [`docs/compiler_rt.md`][ldc-compiler-rt-doc]
- `dlang/dmd` @ `e6baf474` — `compiler/src/dmd/cli.d` (zero sanitizer options), `druntime/src/core/internal/gc/os.d` (mmap pools), `druntime/src/etc/valgrind/valgrind.d`, `druntime/src/core/thread/fiber/package.d`
- `dlang/dub` @ `5efed360` ([source tree][dub-tree]) — `source/dub/commandline.d` (the `$DFLAGS` magic build type), `source/dub/package_.d` (DFLAGS-last, buildType root lookup), `source/dub/project.d` (unittest stripping, the success line), `source/dub/generators/generator.d` (whole-closure buildType, build-ID hashing, bidirectional merges), `source/dub/compilers/buildsettings.d` ([`filterABICriticalFlags`][dub-3111]); [issue #640][dub-640]
- LLVM/compiler-rt — `lib/msan/msan.h` (shadow mapping), [`clang/docs/MemorySanitizer.rst`][msan-rst] (the instrumented-world statement); [GCC instrumentation options][gcc-instr-opts] (`gcc-15.1-instrumentation-options.html`, `[literature]`)
- Runnable probes: [`gc-uaf-blindspot.d`][gc-uaf-probe] (Experiments 13, 18 — the GC blind spot) · [`fiber-asan.d`][fiber-probe] (Experiments 1, 18 — the fiber stack-use-after-return)
- The baseline this page audits against — [sparkles-baseline.md][baseline] (unittest-config flags, the historical event-horizon recipe) — and the design it feeds, [integration-proposal.md][proposal]
- Shared vocabulary: [concepts.md][concepts] ([instrumentation locus][locus], [runtime selection][runtime-selection], [the GC memory blind spot][gc-blind-spot], [instrumented-world requirement][instrumented-world], [fake stack][fake-stack], [fiber annotation][fiber-annotation], [weak-hook control surface][weak-hook])

<!-- References -->

[concepts]: ./concepts.md
[locus]: ./concepts.md#instrumentation-locus
[runtime-selection]: ./concepts.md#sanitizer-runtime-selection
[interceptor]: ./concepts.md#interceptor
[allocator-interception]: ./concepts.md#allocator-interception
[gc-blind-spot]: ./concepts.md#the-gc-memory-blind-spot
[instrumented-world]: ./concepts.md#instrumented-world-requirement
[fake-stack]: ./concepts.md#fake-stack-and-stack-use-after-return
[fiber-annotation]: ./concepts.md#fiber-annotation
[halt-vs-recover]: ./concepts.md#halt-vs-recover
[weak-hook]: ./concepts.md#weak-hook-control-surface
[suppression]: ./concepts.md#suppression
[shadow]: ./concepts.md#shadow-memory
[stw-root-scan]: ./concepts.md#stop-the-world-root-scanning
[client-request]: ./concepts.md#client-request
[definedness]: ./concepts.md#definedness-vs-addressability
[index]: ./
[asan]: ./asan.md
[ubsan]: ./ubsan.md
[tsan]: ./tsan.md
[valgrind]: ./valgrind.md
[baseline]: ./sparkles-baseline.md
[runner-integrations]: ./runner-integrations.md
[comparison]: ./comparison.md
[proposal]: ./integration-proposal.md
[macos-windows]: ./macos-windows.md
[hardware-assisted]: ./hardware-assisted.md
[gc-uaf-probe]: ./examples/gc-uaf-blindspot.d
[fiber-probe]: ./examples/fiber-asan.d
[ldc-tree]: https://github.com/ldc-developers/ldc/tree/v1.41.0
[ldc-compiler-rt-doc]: https://github.com/ldc-developers/ldc/blob/v1.41.0/docs/compiler_rt.md
[dub-tree]: https://github.com/dlang/dub/tree/5efed360e1c9342453bc5dd19339c75981526d83
[dub-3111]: https://github.com/dlang/dub/pull/3111
[dub-640]: https://github.com/dlang/dub/issues/640
[msan-rst]: https://clang.llvm.org/docs/MemorySanitizer.html
[gcc-instr-opts]: https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html
