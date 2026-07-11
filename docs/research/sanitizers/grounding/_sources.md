# Grounding sources — local-artifact map

Lookup table for the per-page verification pass. Every external citation in the
sanitizers survey maps here to a **local** artifact: a repo cloned under `$REPOS`
(pinned below), a PDF/HTML/source capture under `$REPOS/papers/sanitizers/`, or a
recorded experiment transcript. Web is a fallback **only** for the artifacts
marked _cite-by-name_. `$REPOS` = `/home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

**Acquisition:** 2026-07-11, by three recon agents (conventions, environment,
baseline) and seven research workstreams (W1–W7). All repos read at the pinned
SHA; `$REPOS/linux` and `$REPOS/llvm-project` were pre-existing detached
checkouts reused read-only. Every SHA below was re-checked with
`git -C <path> rev-parse HEAD` on 2026-07-11 and matches the worker reports.

## Source repos (pinned to reviewed HEAD)

| Repo                        | Role in the survey                                                        | Path                                 | Branch / tag @ SHA                                                      | Read by                 |
| --------------------------- | ------------------------------------------------------------------------- | ------------------------------------ | ----------------------------------------------------------------------- | ----------------------- |
| llvm-project                | compiler-rt / clang / llvm — the source of truth for every sanitizer      | `$REPOS/llvm-project`                | `main` @ `73802c2e`                                                     | W1 W2 W5 W6 W7 recon    |
| linux (v7.1-rc6)            | tagged-address & MTE ABI, KASAN/KCSAN docs, `arch_prctl` constants        | `$REPOS/linux`                       | detached @ `e43ffb69`                                                   | W7                      |
| dlang/ldc                   | LDC driver/optimizer + druntime fork (fiber/ASan `SupportSanitizers`)     | `$REPOS/dlang/ldc`                   | `feat/wasm` @ `f4d2f831` (content read at tag `v1.41.0` via `git show`) | W1 W2 W3 W4 W6 W7 recon |
| dlang/dmd (PetarKirov fork) | upstream druntime — GC, `etc.valgrind`, fibers, `dmd` CLI (no sanitizers) | `$REPOS/dlang/dmd`                   | `master` @ `e6baf474`                                                   | W2 W3 W4 recon          |
| dlang/dub                   | `DFLAGS`/buildType flag plumbing, ABI-critical propagation, build cache   | `$REPOS/dlang/dub`                   | `master` @ `5efed360` (= installed dub)                                 | W2 W3                   |
| go/go                       | `go test -race` UX + prebuilt-TSan runtime seam                           | `$REPOS/go/go`                       | `master` @ `015343854`                                                  | W2 W5                   |
| rust/rust                   | `-Zsanitizer`/`-Zbuild-std` docs + libtest threading model                | `$REPOS/rust/rust`                   | `main` @ `3bf5c6d9`                                                     | W5                      |
| rust/cargo                  | fingerprint/cache thrash on sanitizer-flag toggle                         | `$REPOS/rust/cargo`                  | @ `71b70c09`                                                            | W5                      |
| rust/cargo-nextest          | process-per-test model ("now, and will always be")                        | `$REPOS/rust/cargo-nextest`          | @ `ae298c47`                                                            | W5                      |
| zig/zig                     | `std.valgrind`, `-fsanitize-c` defaults, per-test allocator windowing     | `$REPOS/zig/zig`                     | `master` @ `1bcd8d9f` (dev — `std.Build`→`Maker` rename)                | W5                      |
| swift/swift-package-manager | `swift test --sanitize=`, `DYLD_INSERT_LIBRARIES` harness injection       | `$REPOS/swift/swift-package-manager` | @ `c84a21b4`                                                            | W5                      |
| cpp/cmake                   | CTest MemCheck wrapper-and-parse + first-class suppression setting        | `$REPOS/cpp/cmake`                   | @ `5bdf88ea`                                                            | W5                      |
| cpp/googletest              | documented `__*_on_report`→`FAIL()` seam; death-test-as-capturer          | `$REPOS/cpp/googletest`              | @ `8240fa7d`                                                            | W5                      |
| cpp/drmemory                | DynamoRIO memory checker — Windows no-recompile analog of memcheck        | `$REPOS/cpp/drmemory`                | @ `3d2b5f9` (2025-12-12)                                                | W6                      |
| python/pytest-valgrind      | in-process client-request count-delta windowing per test                  | `$REPOS/python/pytest-valgrind`      | @ `98ae3524`                                                            | W5                      |
| c/valgrind (3.26.0)         | memcheck V/A-bit model, helgrind/DRD, client-request mechanism            | `$REPOS/c/valgrind`                  | tag `VALGRIND_3_26_0` @ `218cee2f`                                      | W4 W6                   |

**Newly cloned this session** (absent per the environment recon inventory):
`c/valgrind`, `cpp/drmemory`, `cpp/googletest`. The rest were pre-existing
checkouts read in place; none was fetched, cleaned, or modified.

**Reference (not cloned).** Grounded against toolchain-resolved or artifact-listed
sources rather than a git checkout:

- **GCC 15.2 libsanitizer runtimes** — the runtime LDC actually links on this box
  via its gcc fallback: `libasan.so.8`, `liblsan.so.0`, `libtsan.so.2`,
  `libubsan.so.1`, `libhwasan.so.0` under the `gcc-15.2.0-lib` store path
  (`chqq8mpm…`), audited by `nm -D` and `*_OPTIONS=help=1` (W1/W2/W7).
- **nixpkgs compiler-rt** — `llvmPackages_18.compiler-rt` (`l6fvgy9…`,
  18.1.8) restores true `clang_rt` linking via an edited `ldc2.conf`;
  `llvmPackages.compiler-rt` 21.1.7 (`3lim3czb…` linux, `1504f3ry…` darwin)
  supplies the HWASan/GWP-ASan/RTSan/TySan/rtsan runtimes (W1/W3/W6/W7).
- **LDC/DMD import trees** — druntime `core/thread/`, `etc/valgrind/`,
  `ldc/sanitizers_optionally_linked.d`, `ldc2.conf`, the `ldc-1.41.0-include`
  output — read from the nix-store install (W1/W3/W4).
- **Official LDC v1.41.0 release artifacts** — `ldc2-1.41.0-{osx-universal,
windows-multilib,linux-x86_64}` archives, downloaded, listed (`tar -t`/`7z l`
  for the `ldc_rt`/`clang_rt` inventory), then deleted (W3/W6).
- **nixpkgs aarch64-darwin LDC + compiler-rt** — verified without a Mac via
  `cache.nixos.org` NAR listings (`nix store ls/cat --store https://cache.nixos.org`)
  (W6).
- **sparkles working tree** — this repo @ `379e4c7a` (branch `research/sanitizers`)
  read read-only for the baseline (runner shim/impl, unittest dub.sdl configs,
  event-horizon history commits `c9537f96`/`5284b217` via `git show`).

## Papers & captures — `$REPOS/papers/sanitizers/`

Foundational papers (all retrieved 2026-07-11):

| Artifact                                                        | File                                                      | Provenance                                                                                   |
| --------------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| ASan (Serebryany et al., USENIX ATC 2012), 10 pp                | `asan-usenix-atc-2012.pdf`                                | Google research archive; W1                                                                  |
| MSan (Stepanov & Serebryany, CGO 2015), 10 pp                   | `msan-cgo-2015.pdf`                                       | Google research archive; W1                                                                  |
| TSan v1 (Serebryany & Iskhodzhanov, WBIA 2009), 10 pp           | `threadsanitizer-wbia-2009.pdf`                           | Google research archive; W2                                                                  |
| TSan v2 (Serebryany & Potapenko, LLVM RV 2011), 5 pp            | `tsan-dynamic-race-detection-llvm-rv-2011.pdf`            | Google research archive; W2                                                                  |
| Valgrind framework (Nethercote & Seward, PLDI 2007), 6 pp       | `valgrind-framework-pldi-2007.pdf`                        | valgrind.org; W4                                                                             |
| Memcheck shadow (Nethercote & Seward, VEE 2007), 10 pp          | `memcheck-shadow-every-byte-vee-2007.pdf`                 | valgrind.org; W4 (distinct from PLDI — see register R12)                                     |
| Dr. Memory (Bruening & Zhao, CGO 2011), 6 pp                    | `drmemory-practical-memory-checking-cgo-2011.pdf`         | W6                                                                                           |
| GWP-ASan (Serebryany et al., arXiv 2311.09394 v2), 9 pp         | `gwp-asan-sampling-arxiv-2311.09394.pdf`                  | arXiv; W7 (`file` mis-reports 2 pp — linearized PDF; `pdfinfo` = 9)                          |
| Memory Tagging (Serebryany et al., arXiv 1802.09517), 14 pp     | `memory-tagging-arxiv-1802.09517.pdf`                     | arXiv; W7 (the HWASan design-doc citation)                                                   |
| Optimized Memory Tagging on AmpereOne (arXiv 2511.17773), 23 pp | `ampereone-optimized-memory-tagging-arxiv-2511.17773.pdf` | arXiv; W7 (first datacenter MTE CPU)                                                         |
| Arm Armv8.5-A **Memory Tagging Extension** white paper, 55 pp   | `arm-mte-whitepaper.pdf`                                  | Arm; W7 — **freely downloadable, NOT registration-gated** (verified: PDF 1.7, 55 pp, 662 KB) |

Docs, specs & config captures (all retrieved 2026-07-11 unless noted):

| Artifact                                                        | File(s)                                                                                                                      | Provenance                                                                                          |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| clang sanitizer docs (ASan / LSan / MSan / UBSan)               | `clang-docs-{address,leak,memory,undefined-behavior}-sanitizer.{html,rst}`                                                   | clang.llvm.org + byte copies of the `.rst` from `llvm-project@73802c2e` (line-precise citation); W1 |
| clang ThreadSanitizer doc                                       | `clang-threadsanitizer-docs.html`                                                                                            | clang.llvm.org; W2                                                                                  |
| google/sanitizers TSan algorithm wiki (**v2 — stale**)          | `google-sanitizers-wiki-threadsanitizeralgorithm.md`                                                                         | GitHub wiki; W2 (v3 verified against `tsan_shadow.h`)                                               |
| Go race-detector manual (`GORACE`, exit 66)                     | `go-race-detector-article.html`                                                                                              | go.dev; W2 (reused by W5)                                                                           |
| GCC 15.1 instrumentation-options (`-fsanitize` reference)       | `gcc-15.1-instrumentation-options.html`                                                                                      | gcc.gnu.org; W3 (GDC column)                                                                        |
| LDC ASan intro (Engelen 2017 — fake stack, `SupportSanitizers`) | `ldc-addresssanitizer-engelen-2017.html`                                                                                     | johanengelen.github.io; W3                                                                          |
| Memcheck manual 3.26.0                                          | `memcheck-manual-3.26.0.html`                                                                                                | valgrind.org; W4                                                                                    |
| Rust unstable-book sanitizer page                               | `rust-unstable-book-sanitizer.md`                                                                                            | doc.rust-lang.org (byte-matches `rust@3bf5c6d9`); W5                                                |
| SwiftPM DocC `swift test` page                                  | `swiftpm-docc-swifttest.md`                                                                                                  | docs.swift.org (matches `swift-pm@c84a21b4`); W5                                                    |
| Bazel test-encyclopedia + user manual                           | `bazel-test-encyclopedia.html`, `bazel-user-manual.html`                                                                     | bazel.build; W5                                                                                     |
| rules_cc + bazel forwarding-stub toolchain configs              | `rules-cc-unix-toolchain-config.bzl`, `bazel-unix-cc-toolchain-config.bzl`                                                   | raw.githubusercontent.com `main`/`master` (unpinned); W5                                            |
| Envoy `.bazelrc` (`--config=asan` convention exhibit)           | `envoy-bazelrc.txt`                                                                                                          | raw.githubusercontent.com `main` (unpinned); W5 `[lit]`                                             |
| KDE ECM `ECMEnableSanitizers.cmake` (184 lines)                 | `ecm-enable-sanitizers.cmake`                                                                                                | invent.kde.org; W5                                                                                  |
| MSVC ASan docs — 7 MS Learn pages (ms.date 2026-05-28)          | `msvc-{asan,asan-building,asan-shadow-bytes,asan-runtime,asan-continue-on-error,asan-known-issues,fsanitize-reference}.html` | learn.microsoft.com; W6                                                                             |
| WinDbg Time Travel Debugging overview                           | `windbg-ttd-overview.html`                                                                                                   | learn.microsoft.com; W6                                                                             |
| Valgrind platforms page + LouisBrunner macOS-fork README        | `valgrind-platforms-page.html`, `valgrind-macos-fork-readme.md`                                                              | valgrind.org / GitHub; W6 (prior run)                                                               |
| Clang 20.1.0 release notes (RTSan + TySan introduced)           | `llvm-20.1.0-clang-release-notes.html`                                                                                       | releases.llvm.org; W7                                                                               |
| Apple Memory Integrity Enforcement blog (2025-09-09)            | `apple-memory-integrity-enforcement-blog.html`                                                                               | security.apple.com; W7 (MIE/EMTE on A19, no M-series)                                               |
| Android HWASan + MTE docs                                       | `android-hwasan-docs.html`, `android-mte-docs.html`                                                                          | source.android.com; W7                                                                              |
| Project Zero "first handset with MTE" (Pixel 8, 2023-11)        | `googleprojectzero-first-handset-with-mte.html`                                                                              | googleprojectzero.blogspot.com; W7                                                                  |

Provenance ledgers with the full URL map: `w1-retrieval-notes.md`,
`RETRIEVAL-NOTES-w2.md`, `w3-retrieval-notes.md`, `w4-retrieval-notes.md`,
`w5-retrieval-notes.md`, `w6-retrieval-notes.md`, `w7-retrieval-notes.md`
(all in `$REPOS/papers/sanitizers/`).

## Gated primaries → cite-by-name + secondary grounding

Unlike the CPU-PMU survey (DDI 0487, Intel SDM), the sanitizers corpus is
**essentially ungated** — the DDI-0487 analog here, the Arm MTE white paper, was
freely downloadable (W7). The only items cited by name without a saved file are
minor web pointers:

| Citation                                                                    | Why not saved                                    | Ground instead against                                                           |
| --------------------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------------------------------------- |
| Arm Neoverse N2/V2 product pages (MTE in the IP)                            | marketing pages; pointer only                    | Arm MTE white paper + `linux/Documentation/.../memory-tagging-extension.rst`     |
| ldc-developers/ldc issues **#3760** (Windows ASan × exceptions), #3742      | GitHub issue threads (fetched live at authoring) | `driver/linker-msvc.cpp` behavior + the issue title/state (open 2021→2026-07-11) |
| llvm/llvm-project **PR #93770** (LLVM-20 static-asan removal), MSVC devblog | mailing-list / blog                              | LDC `linker-msvc.cpp` `LDC_LLVM_VER >= 2000` thunk guard (`[source-verified]`)   |
| msys2/MINGW-packages **#3163** (MinGW libsanitizer blocked)                 | issue thread                                     | absence is the finding — no ASan runtime in the MinGW ABI (W6 C19)               |

## Experiment environments (recorded per experiment in pages + ledgers)

| Bed                           | Facts                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `x86_64-linux` (primary)      | NixOS **25.11** (Xantusia, `0c88e1f2`), kernel **6.18.26**, AMD **Ryzen 9 7940HX** (Zen 4, family 25 model `0x61`, 16c/32t). **LDC 1.41.0** (LLVM 18.1.8, fe 2.111.0), **DMD 2.112.1**, **dub 1.42.0-beta.1** (store `dub-1.43.0-alpha-5efed36`), **GCC 15.2** (`gcc-wrapper-15.2.0`, `CC`) + its libsanitizer runtimes; **valgrind 3.26.0**, **clang 21.1.7** / compiler-rt 18.1.8 & 21.1.7 (all via `nix shell`); **gdc 11.5.0** (`nixos-25.05`, ASan-workaround only). All experiments unprivileged.  |
| `aarch64-darwin` (mac-bsn)    | macOS **26.3.1** (25D771280a), Darwin 25.3.0, Apple **M4 Max** (T6041), **Apple clang 21.0.0**, **Determinate Nix 3.17.1**, SIP enabled, non-root. **Hardware runs limited to the recon smoke test** (Apple-clang ASan heap-UAF caught, `abort_on_error=1` → exit **134**). W6's D+clang batch (E-M1/E-M3) **BLOCKED** — the ssh key sat locked in gpg-agent (non-interactive signing had no pinentry surface); mechanism artifact-verified via `cache.nixos.org`, fixtures staged for a trivial re-run. |
| Windows                       | **none** — docs + open source only (MSVC MS-Learn, Dr. Memory clone, LDC `linker-msvc.cpp` + release-artifact listings); nothing Windows-tagged is hw-verified.                                                                                                                                                                                                                                                                                                                                          |
| `aarch64-linux` / MTE silicon | **none** — HWASan exercised only via **x86_64 LAM aliasing mode** on the primary box; plain HWASan and all MTE claims are source (kernel docs, compiler-rt) + literature. No MTE silicon in the fleet — the M4 has **no MTE** (Apple EMTE debuted on A19, Sept 2025); the `sysctl` probe was blocked (same ssh key).                                                                                                                                                                                     |
