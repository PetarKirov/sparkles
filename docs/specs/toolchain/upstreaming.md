---
status: draft
owner: sparkles
reviewed: 2026-11-25
---

# The Sparkles toolchain — Upstreaming plan

## Abstract

Sparkles builds with its own branches of DMD, LDC, LLVM, Phobos and the
dlang.nix packages, because the programs it ships need compiler fixes and
capabilities that no upstream release has. This plan lists every change those
branches carry: what each change is, the commits that carry it, the
requirement that needs it, where it stands upstream, and the order in which
it can be proposed. Each entry ends merged upstream, superseded by an
upstream fix, or kept in the fork for a stated reason, so that the forks
carry nothing they do not have to.

## Introduction

A compiler fork is cheap to start and expensive to keep. Each upstream
release has to be merged into it, and each change it carries makes the merge
slower. A fork whose changes are not upstreamed becomes permanent, and its
owner ends up carrying other people's fixes as well as their own.

Changes reach the forks from many places: the
[toolchain specification](./SPEC.md), its [WASI](./wasi.md) page, the
[shader toolchain](../shaders/toolchain.md), the
[build graph](../build-primitives/build-graph/SPEC.md), and the language server
and formatter ([dmd-lsp](../dmd-lsp/index.md), [dmd-fmt](../dmd-fmt/index.md)).
Each page records why it needs its change, but none says where the change
stands upstream. The DMD language-server branch kept its own plan in the fork,
and that plan fell behind the branch. Without one list, a change that upstream
has already fixed stays in the fork. A change that could be proposed is never
proposed, and nothing shows which proposal is waiting on another.

This page is that list, and it supersedes the plan the language-server
branch kept. A change gets one entry, under the fork that carries it. The
entry names the fork commit, pinned to its full hash, and the requirement
that needs the change. It also names the upstream target, the state there
with links to issues and pull requests, and what blocks the next step.
[TCD2](./decisions.md#tcd2-upstreaming-after-production-use) decides _when_ a
change is proposed: after the programs that depend on it ship on the
toolchain. This page decides _what_ is proposed and in _which order_; until
TCD2 allows it, each change is kept ready to submit.

Most entries exist because a specification needs them; an entry needed only
by work no specification covers yet says so. Commits that only keep a fork
building are listed too, such as support for an LLVM that upstream LDC does
not build with, because the changes that need them cannot be proposed
without them. Per-commit regression tests, and whether each test failed with
its change reverted, are recorded once, in the
[fork review](./testing.md#fork-review); this page links there rather than
repeating them.

[§1](#_1-the-rules) states the rules an entry follows. §2 and §3 list the
entries of DMD's two branches, the toolchain's and the language server's;
§4 those of LDC; §5 those of LLVM and Phobos; and [§6](#_6-dlang-nix) those
of dlang.nix, whose packages are upstreamed together with the commits they
build. [§7](#_7-order-and-blockers) gives the order of submission and the
blockers across forks, and [§8](#_8-reports-to-file) the reports and
pull-request texts that are ready to file.

## 1. The rules

**TCU1: One entry per change.** Every change carried by the DMD, LDC, LLVM or
Phobos forks, or by dlang.nix's toolchain branch, **must** have exactly one
entry on this page. The entry names its fork commits by full hash, the
requirement that needs it (or that none does yet), its upstream target and
its state (TCU3).

**TCU2: Upstream form.** A change that targets an upstream repository
**must** exist as one commit on a `fix/*` branch of the fork, on the upstream
default branch. The commit carries its regression test in the upstream test
suite's own format (TC3). Where the toolchain branch (`sparkles/main`)
carries the same change, the two commits differ only by the rebase.

**TCU3: States.** An entry is in exactly one of these states:

| State        | Meaning                                                                                |
| ------------ | -------------------------------------------------------------------------------------- |
| `fork-only`  | Deliberately not proposed; the entry says why                                          |
| `ready`      | In upstream form (TCU2), not yet proposed                                              |
| `needs-work` | Not yet in upstream form, or missing its regression test; the entry names what is left |
| `reported`   | An upstream issue describes the problem; no pull request yet                           |
| `proposed`   | An upstream pull request is open                                                       |
| `blocked`    | Waits for another entry or an external change, which the entry names                   |
| `superseded` | Upstream fixed the problem its own way; drop the fork commit at the next rebase        |
| `merged`     | Upstream merged it; drop the fork commit at the next rebase                            |

**TCU4: Drop on rebase.** When a fork is rebased onto an upstream revision
that contains a `merged` or `superseded` change, the fork commit **must** be
dropped. The fork's regression test **must** be run on the result first: a
superseded change can be a partial fix. The entry then leaves this page; the
fork's history and the linked upstream change record it.

**TCU5: Order.** A change **must not** be proposed before the entries it
depends on have been merged upstream. §7 names those dependencies.

## 2. DMD: `sparkles/main`

[PetarKirov/dmd `sparkles/main`](https://github.com/PetarKirov/dmd/compare/999db40464f5a80e581ab567d916b72d15dbf1f1...d19ed4c2ecc67ecdbd64f550351fdb3e4dddb1d6)
is DMD master with the commits of UD1–UD8 and UD10, plus two test-only
commits (`21663b0b95`, UD8's test under `-inline`; `d19ed4c2ec`, UD5's test);
UD9 exists only as its `fix/*` branch. `sparkles/main` is the shell's `dmd`, built
by dlang.nix's `dmd-sparkles`. Every entry has its single-commit `fix/*`
branch.

| ID   | Change                                                                                                             | Fork commit, `fix/*` branch                                                                                                                                                                                                                  | Needed by                                                            | Upstream                                                                                                                                                                                                                                                                               | State        |
| ---- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| UD1  | `-lib` writes deterministic member headers (no time, uid or gid)                                                   | [`b737e1b615`](https://github.com/PetarKirov/dmd/commit/b737e1b615ba0c1eb02c3533a92f8d4038c56bac), `fix/deterministic-lib` [`e290e20084`](https://github.com/PetarKirov/dmd/commit/e290e20084a2eff33e04b8d5c5fd32188c24b315)                 | Build graph decision D63; `ci cache verify --rerun`                  | No issue or PR                                                                                                                                                                                                                                                                         | `ready`      |
| UD2  | `-ffile-prefix-map=<old>=<new>` for paths in objects, debug info and coverage                                      | [`bd40b72a72`](https://github.com/PetarKirov/dmd/commit/bd40b72a72b3ca095f8186a56eafac5f281ada2b), `fix/file-prefix-map` [`9cf869b651`](https://github.com/PetarKirov/dmd/commit/9cf869b6513274f7cc5d1e93ee58d85eb442c234)                   | Build graph BGA5, D63                                                | No issue or PR; the same option as LDC's (UL10)                                                                                                                                                                                                                                        | `ready`      |
| UD3  | Write an output file in as many `write()` calls as it takes (files over 2 GiB)                                     | [`dffd1fc4fe`](https://github.com/PetarKirov/dmd/commit/dffd1fc4febe20f29e85e57e922f1570e05a9593), `fix/file-write-large` [`6c20eb1bc3`](https://github.com/PetarKirov/dmd/commit/6c20eb1bc369b47a64bca0a911d1cd7c0de72b10)                  | Builds under `-ftime-trace` (`hue` at granularity 0)                 | No issue or PR; LDC carries it as UL6                                                                                                                                                                                                                                                  | `ready`      |
| UD4  | ImportC accepts a matching redeclaration of a tagged-type variable (Wayland protocol code)                         | [`363521036c`](https://github.com/PetarKirov/dmd/commit/363521036c1923567f79a7e3a5082c9ea835a17f), `fix/importc-tag-redeclaration` [`1529830`](https://github.com/PetarKirov/dmd/commit/15298303f7c9636f5184696943e1d87909d33901)            | `sparkles:wsi` on Wayland                                            | [dlang/dmd#24440](https://github.com/dlang/dmd/pull/24440) (fixes #24438) merged; it compares tag kind and identifier, the fork also qualifiers                                                                                                                                        | `superseded` |
| UD5  | Emit a struct instance's TypeInfo members when the instance's codegen is elided                                    | [`b675a6d14d`](https://github.com/PetarKirov/dmd/commit/b675a6d14dd45c1b946dee8040e38fe2e283e790), `fix/typeinfo-skipped-instance-members` [`a0920c9b9b`](https://github.com/PetarKirov/dmd/commit/a0920c9b9beafa3d56784ffc6869ca7637eaee75) | `dub test` with DMD (unittest builds against libraries link)         | [dlang/dmd#23731](https://github.com/dlang/dmd/issues/23731) open; [dlang/dmd#23732](https://github.com/dlang/dmd/pull/23732) takes the same approach, contested; [dlang/dmd#23832](https://github.com/dlang/dmd/pull/23832) merged, which the fork's base has, does not fix this case | `ready`      |
| UD6  | ImportC's inline-use scan does not follow an `alias` into its function (stack overflow)                            | [`56242d3c97`](https://github.com/PetarKirov/dmd/commit/56242d3c9718967bb326937ef25b47108e3f71ad), `fix/importc-inline-scan-alias-cycle` [`012e1e7163`](https://github.com/PetarKirov/dmd/commit/012e1e7163f88c05b45710ec4d9b715989d89b35)   | ImportC builds of C headers that alias functions                     | No issue or PR                                                                                                                                                                                                                                                                         | `ready`      |
| UD7  | Keep a default argument's cast when the call copies it (libasync's `cast(EPosix) errno()`)                         | [`e0b6e795ff`](https://github.com/PetarKirov/dmd/commit/e0b6e795ff3c9841a1fb5d944b3b422cd8e1c3d3), `fix/default-arg-cast` [`e39e9652c2`](https://github.com/PetarKirov/dmd/commit/e39e9652c2ff42421bd65a86ca68c52dbe63afc2)                  | `sparkles:event-horizon` on libasync                                 | No issue or PR                                                                                                                                                                                                                                                                         | `ready`      |
| UD8  | A `scope` lazy variadic array of delegates needs no closure ([§2.1](#_2-1-ud8-scope-lazy-variadic-arrays))         | [`0964acb1e0`](https://github.com/PetarKirov/dmd/commit/0964acb1e000222b62027b734e7bd6daebf56181), `fix/scope-lazy-variadic` [`d8d29a0c3d`](https://github.com/PetarKirov/dmd/commit/d8d29a0c3d42cfc1a66bd7ed87887319a9f42696)               | No requirement yet: the UI builder prototype's `@nogc` lazy children | [dlang/dmd#22885](https://github.com/dlang/dmd/issues/22885) open, no PR; PR text in §8                                                                                                                                                                                                | `reported`   |
| UD9  | CTFE of `core.simd` vector operations                                                                              | not on `sparkles/main`; `fix/ctfe-vector-ops` [`18766b9dbd`](https://github.com/PetarKirov/dmd/commit/18766b9dbd9f676151c4a1e4ef2160d4af3a5446)                                                                                              | The DMD side of UL5 (shader vector code in CTFE)                     | [dlang/dmd#21823](https://github.com/dlang/dmd/issues/21823) open, no PR                                                                                                                                                                                                               | `reported`   |
| UD10 | Read a full expression's value before destroying its temporaries (`return T(9).v`, and `T(9).get` under `-inline`) | [`333c76284f`](https://github.com/PetarKirov/dmd/commit/333c76284f35b7a3f8b31f1abf5ada1c99a1bc4a), `fix/temporary-lvalue-dtor` [`311ee8e0f2`](https://github.com/PetarKirov/dmd/commit/311ee8e0f220cc000953e883eb79cec9d3ec6cf2)             | UD8's test under `-inline`; any `lazy` argument reading a temporary  | No issue or PR; issue and PR text in §8                                                                                                                                                                                                                                                | `ready`      |
| UD11 | A `ref` return of a call's `ref` result through a temporary returns a stack copy                                   | none: to report                                                                                                                                                                                                                              | Nothing yet                                                          | No issue yet; text in §8                                                                                                                                                                                                                                                               | `needs-work` |

UD5's test, `dshell/typeinfo_elided_instance.d`, is reduced from
`sparkles:versions`: a library built without `-unittest`, and an importer
built with `-unittest -allinst` whose `version (unittest)` function emits
`_d_arrayliteralTX!(Interval!U3)`, and with it `Interval!U3`'s TypeInfo. The
`fix/*` commit carries it; `sparkles/main` adds it as `d19ed4c2ec`. UD4 is dropped at the next rebase
once the fork's test passes with dlang/dmd#24440 alone (TCU4). The
time-trace fix that LDC carries as UL7 needs no DMD entry, because
[dlang/dmd#24386](https://github.com/dlang/dmd/pull/24386) is merged and
`sparkles/main` contains it.

### 2.1 UD8: `scope` lazy variadic arrays

The spec's
[best practice](https://dlang.org/spec/function.html#lazy_variadic_functions)
says that `scope` on a lazy variadic array of delegates prevents a closure,
because `scope` means the delegates do not escape. Upstream DMD does not: the
argument is a slice of an array literal of delegate literals, which the
check that clears a `scope` argument's closure never looks into, so it
rejects a `@nogc` caller. UD8 makes the caller keep the frame on its
stack, and closes the two holes that doing only that would open:

- Every typesafe variadic array is implicitly `scope`. That `scope` covers
  only the array, which the caller builds on its stack; it is marked
  inferred, so it is not mangled. Since dlang/dmd#14324 a declared `scope`
  gets the same mark, so a caller cannot tell the two apart. Under
  `-preview=dip1000`, clearing the closure of every such argument therefore
  drops the closure of a callee that legally stores its delegates as well
  (a test read 21 instead of 42 from the dead frame). A declared `scope`
  stays declared, and only it removes the closure; it is mangled, as it
  was before 2.101.
- `scope` is not transitive, so a `@safe` callee can store `xs[0]`. For
  an array of zero-parameter delegates whose `scope` is not the implicit
  one, escape analysis takes an element for the array's value. Storing,
  returning, appending (`~`, `~=`), slice-copying, or forwarding the array
  to a variadic parameter without a declared `scope` is an error in `@safe`
  code, and an override may not drop the `scope`.

What stays open, all of it outside the change: `@trusted` code that copies
the elements is not checked (druntime's `_dup`, so `xs.dup`). A function
pointer type with a `scope` parameter accepts a function without one, as it
does for any `scope` parameter. Without `-preview=dip1000`, an escape is
silently accepted, as for any `scope` parameter. Breaking changes for the
pull request's changelog: the mangling of declared-`scope` typesafe variadic
parameters, and the new `@safe` errors. The owner accepted both for upstreaming (2026-11-25). The tests are
`compiler/test/{runnable,compilable,fail_compilation}/test22885*.d`; LDC
carries the same commit as UL20, with an IR test and an ASan test.

## 3. DMD: `dmdserver-dub`

[PetarKirov/dmd `dmdserver-dub-v2.114.0`](https://github.com/PetarKirov/dmd/compare/b6b0cb48e2484d591465494621e158ebc8c74a65...270f79d071bb59bfd6c30185b426b135c88a10d0)
is
[rainers/dmd `dmdserver`](https://github.com/rainers/dmd/tree/b6b0cb48e2484d591465494621e158ebc8c74a65),
the language-server patch set on DMD v2.114.0, plus the commits below. It is
the library that `sparkles:dmd-lsp` and `sparkles:dmd-fmt` build on.
This section supersedes the fork's own `PLAN-UPSTREAMING.md`
([last version](https://github.com/PetarKirov/dmd/commit/270f79d071bb59bfd6c30185b426b135c88a10d0);
dmd-fmt cited [`c562711`](https://github.com/PetarKirov/dmd/commit/c562711dbd4685c4e4f7bd5ff46e1a306c932259)).
That plan lists rows 1–15. It marks rows 3 and 7 done, upstream having made
them unnecessary. Its row 15, `-ffile-prefix-map`, is UD2.

The commits are named by their hash on the branch tip, then by their hash in
the state Sparkles pins (`e0be436ba4`, tag `sparkles-pin/dmdserver-dub-e0be436ba4`).

| ID   | Change                                                                             | Commit (tip / pinned), `fix/*` branch                                                                                                                                                                                                                  | Needed by                             | Target                        | State       |
| ---- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------- | ----------------------------- | ----------- |
| US1  | `versions "LanguageServer"` in the four library subpackages                        | [`9b8950e7dc`](https://github.com/PetarKirov/dmd/commit/9b8950e7dc3afde527bcfd56d5167c84092cae7d) / `bde0e8accc`                                                                                                                                       | dmd-lsp BLD1                          | none                          | `fork-only` |
| US2  | `root.aav`: typed keys from `asRange` under `version(GC)`                          | [`f568c8182d`](https://github.com/PetarKirov/dmd/commit/f568c8182dfabc921d5aac28ac75ee0a380fe3db) / `8fea76c042`                                                                                                                                       | dmd-lsp BLD1                          | rainers/dmd `dmdserver`       | `ready`     |
| US3  | dub: drop `astbase.d` from `dmd:parser`                                            | [`706ea87c3d`](https://github.com/PetarKirov/dmd/commit/706ea87c3d915fb56f1161a0856d7c88e871a577) / `f0d906d555`                                                                                                                                       | dmd-lsp BLD1, BLD4                    | none                          | `fork-only` |
| US4  | `doc.d`: the per-symbol ddoc machinery as a library API                            | [`cfe48eef1e`](https://github.com/PetarKirov/dmd/commit/cfe48eef1e14e1d97a944aeb0a7d10d77b4eecdf) / `5ab681e9d7`, `fix/doc-library-api` [`58f56a915a`](https://github.com/PetarKirov/dmd/commit/58f56a915aa76787b715351839bba8019076d3e6)              | dmd-lsp L14, DOC3, DOC4               | dlang/dmd (design discussion) | `ready`     |
| US5  | `parse.d`: keep documented-unittest bodies outside the root module                 | [`68b32e19c1`](https://github.com/PetarKirov/dmd/commit/68b32e19c1c982c2773ac61dd0cf50c8153b83f4) / `ea88375142`                                                                                                                                       | dmd-lsp L28, DDC15                    | rainers/dmd `dmdserver`       | `ready`     |
| US6  | DMDLIB lexer: `commentToken` desync and missing whitespace token on U+2028/U+2029  | [`c4a65297d3`](https://github.com/PetarKirov/dmd/commit/c4a65297d38d4fe290a89c31a661c6c03aebf6b4) / `21a89a5368`, `fix/lexer-dmdlib-line-separators` [`21ea987474`](https://github.com/PetarKirov/dmd/commit/21ea98747474769117e3974fe30e932c8c2ad80e) | dmd-fmt S1                            | dlang/dmd                     | `ready`     |
| US7  | `dmd:lexer` links standalone (`rootobject.d`, `astenums.d`)                        | [`fe25ba39e3`](https://github.com/PetarKirov/dmd/commit/fe25ba39e3e8efa7dc790e42975fad807c4ef7fe) / `d807e7a579`, `fix/dub-lexer-standalone` [`e19e617bb3`](https://github.com/PetarKirov/dmd/commit/e19e617bb33c5d406a165c66ebf07300e7edfcca)         | dmd-fmt S1                            | dlang/dmd                     | `ready`     |
| US8  | `Target.unrestrictedVectors`                                                       | [`b519d956f9`](https://github.com/PetarKirov/dmd/commit/b519d956f90d4a490ae6c15fb07afbeafc3d110f) / `37dc39aa15`, `fix/target-unrestricted-vectors` [`9c09d11f41`](https://github.com/PetarKirov/dmd/commit/9c09d11f41f4f9c143c1e1b8e986d6a806c716e1)  | dmd-lsp TGT2, L29                     | dlang/dmd                     | `ready`     |
| US9  | `initDMD(…, vendorVersion, configureParams)`                                       | [`5c18ba5ba7`](https://github.com/PetarKirov/dmd/commit/5c18ba5ba714757a696e1914526ca964e791f6d2) / `3dc4deaa27`, `fix/initdmd-vendor-params` [`202135a190`](https://github.com/PetarKirov/dmd/commit/202135a1904640aaed3d8b0051ca5eae6b3bfa74)        | dmd-lsp TGT2, TGT4                    | dlang/dmd                     | `ready`     |
| US10 | dub: native assembler implementations and the C preprocessor out of `dmd:frontend` | [`2cb16382bd`](https://github.com/PetarKirov/dmd/commit/2cb16382bd4e6a524403b1b2eca394f13a00f407) / `cd4bc435a2`, `fix/dub-frontend-native-impls` [`6e1b4f9e53`](https://github.com/PetarKirov/dmd/commit/6e1b4f9e532d2321cb5587237a37558d94ccf35a)    | dmd-lsp's frontend-only closure, COR7 | dlang/dmd and the fork        | `ready`     |

The branch's five other commits only edit the fork's `PLAN-UPSTREAMING.md`
and leave the fork with it. The branch is the state Sparkles pins,
`e0be436ba4`, tagged `dmdserver-dub/2.113.0-beta.1+ls.5` with `+ls.1`–`+ls.4`
on its history, as dmd-lsp BLD1 requires. The tip-side hashes above are
those of its rebase onto v2.114.0, kept on branch `dmdserver-dub-v2.114.0`
(and tag `backup/dmdserver-dub-v2.114.0-rebase`) until dmd-lsp moves to that
frontend, whose API changes it does not yet build against.

No row has an upstream issue or pull request. US1 and US3 stay in the fork
until the language-server patch set itself is upstream; US2 and US5 go to
that patch set's branch. The fork's plan also records three findings about
DMD as a library, which are reports to file rather than fork changes: the
lexer's output depends on hidden `Id` state (`__EOF__`, `#line`);
`Identifier.idPool` is not thread-safe, so concurrent lexing crashes; and
`commentToken` cannot be combined with `doDocComment`.

## 4. LDC: `sparkles/main`

[PetarKirov/ldc `sparkles/main`](https://github.com/PetarKirov/ldc/compare/df98a635a7ba665d8907c7cfd7cbd0f2f1aa7810...873265a00bfbcaf5b01ae9c6572325e176c3bc37)
is LDC master with 97 commits. The fork review lists each with its
regression test and an "Upstreamable" verdict. Here they are grouped by the
pull request each group would become. Commits are named by short hash within
that pinned range. The fork has no `fix/*` branches yet, so no LDC entry is
in upstream form (TCU2); that conversion is the first step of each group.

| ID   | Change                                                                                                      | Commits                                                                                                                                                                                        | Needed by                                                                    | Upstream                                                                                                                                                                                    | State        |
| ---- | ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| UL1  | dcompute's Vulkan target                                                                                    | [`0f3f2daa31`](https://github.com/PetarKirov/ldc/commit/0f3f2daa31b2b2be992461d635488723629b229a) (Pham Quang Ha's)                                                                            | Shader toolchain SHT1, TC1                                                   | [ldc-developers/ldc#5132](https://github.com/ldc-developers/ldc/pull/5132) open                                                                                                             | `proposed`   |
| UL2  | Shader stages, interfaces, resources and control flow on the Vulkan target                                  | 34 commits on UL1, from `7f191ac13f` to `290b691e45`; test-only `0f593e4b6f`, `82d94e5ba4`, `c73f807bcb`, `fb95498594`, `3e4d55745f`                                                           | SHT1 and the shader specifications                                           | none                                                                                                                                                                                        | `blocked`    |
| UL3  | Name the `spirv-opt` an optimized Vulkan compilation runs                                                   | [`64e6453968`](https://github.com/PetarKirov/ldc/commit/64e6453968ca5deff80d4b61101190600513ca2c)                                                                                              | Shader build SHP11, build graph BGG5                                         | none                                                                                                                                                                                        | `blocked`    |
| UL4  | Size and alignment of odd-width vectors                                                                     | `a7aff0a499`, `6a1ecf48e6`                                                                                                                                                                     | SHT1 (vector types)                                                          | none; the DMD side is US8                                                                                                                                                                   | `needs-work` |
| UL5  | CTFE of `core.simd` vector operations                                                                       | `387c291ebf`, `4e7e38373c`                                                                                                                                                                     | Shader vector code                                                           | [dlang/dmd#21823](https://github.com/dlang/dmd/issues/21823); upstream as UD9                                                                                                               | `reported`   |
| UL6  | Write a frontend output file in as many `write()` calls as it takes                                         | [`4aa7f4a1a9`](https://github.com/PetarKirov/ldc/commit/4aa7f4a1a98ecf939354ecec233a0dcd52dd0663)                                                                                              | Builds under `-ftime-trace`                                                  | upstream as UD3, reaching LDC through a frontend merge                                                                                                                                      | `ready`      |
| UL7  | Print a template argument in use without expanding it (time traces)                                         | [`0b25dd4ad7`](https://github.com/PetarKirov/ldc/commit/0b25dd4ad7c55e22ef243feb2ab1fed154067927)                                                                                              | Builds under `-ftime-trace`                                                  | [dlang/dmd#24386](https://github.com/dlang/dmd/pull/24386) merged                                                                                                                           | `superseded` |
| UL8  | ImportC: matching tagged-type redeclarations                                                                | [`929e60e167`](https://github.com/PetarKirov/ldc/commit/929e60e167d6cffd121857f53b0c1d5653ad862b)                                                                                              | `sparkles:wsi` on Wayland                                                    | [dlang/dmd#24440](https://github.com/dlang/dmd/pull/24440) merged (UD4)                                                                                                                     | `superseded` |
| UL9  | Precedence of an interpolated expression sequence                                                           | [`c1490a15c7`](https://github.com/PetarKirov/ldc/commit/c1490a15c7089be41c1c4ab86e61a3ba6477ac36)                                                                                              | WebAssembly tech debt WTD30                                                  | none; a DMD frontend change                                                                                                                                                                 | `needs-work` |
| UL10 | `-ffile-prefix-map` and `-fmacro-prefix-map`, and the paths they map                                        | [`3d8b19d533`](https://github.com/PetarKirov/ldc/commit/3d8b19d5336e6ca960f36c3ddca6d1a6ade617af), `a19fec3f58`, `bd9396c726`, `8d5c3c8887`                                                    | TC15, TC13, build graph BGA5                                                 | [ldc-developers/ldc#5039](https://github.com/ldc-developers/ldc/pull/5039) (`-fdebug-prefix-map`) merged; [ldc-developers/ldc#3908](https://github.com/ldc-developers/ldc/issues/3908) open | `ready`      |
| UL11 | Dependency output: ImportC headers in `-makedeps`, `-makedeps-absent`, `-makedeps-digests`                  | `ca5abb238f`, `6ebdb35ffb`, `10d6c6b987`, [`7bee3fbdeb`](https://github.com/PetarKirov/ldc/commit/7bee3fbdebe0e7b30ca819ef4e535e301bdad425)                                                    | Build graph BGK2, BGK7, BGG5; SHP11                                          | none; new options need design agreement                                                                                                                                                     | `needs-work` |
| UL12 | Name the time trace after the output when no file is given                                                  | [`84afab43cc`](https://github.com/PetarKirov/ldc/commit/84afab43ccd4d89cb19d5af4cbc7ff8909295b05)                                                                                              | Builds under `-ftime-trace`                                                  | none                                                                                                                                                                                        | `ready`      |
| UL13 | Compile-time `real` in the target's format on any host                                                      | [`6f473423a2`](https://github.com/PetarKirov/ldc/commit/6f473423a207069788d5c999566db6d6bef3db99)                                                                                              | TCW11                                                                        | none                                                                                                                                                                                        | `ready`      |
| UL14 | Building against LLVM main (24.0.0git)                                                                      | `da17f6c69a`, `1e0ee44092`, `10040e9a4c`, `170d3d0b18`, `e329860504`, `d6fa02fee6`, `1cd64184fe`                                                                                               | TC2                                                                          | none; LDC does not support LLVM 24                                                                                                                                                          | `blocked`    |
| UL15 | WebAssembly exception handling and WASI                                                                     | `e8193632ae`, `a23cd6c137`, `f354aef01b`, `f3080882e0`, `400504c38b`, `7646322d77`, `4e5ead1887`, `3948ae9c99`, `66e41cd8c9`, `f62832cc17`; test-only `288a375ba5`, `1bcf7f50a4`, `abe32ad1c4` | WASI TCW3, TCW5, TCW7, TCW9, TCW10; TCM4                                     | Wasm EH in [#5162](https://github.com/ldc-developers/ldc/pull/5162), [#5227](https://github.com/ldc-developers/ldc/pull/5227) merged                                                        | `blocked`    |
| UL16 | Bionic x86 scans TLS through `__tls_get_addr`                                                               | `f1609f5143`, test `0a4e8b9a9f`                                                                                                                                                                | TC21 (Android)                                                               | [ldc-developers/ldc#5313](https://github.com/ldc-developers/ldc/pull/5313) merged, from the fork owner's [#5311](https://github.com/ldc-developers/ldc/issues/5311)                         | `superseded` |
| UL17 | Stack traces, `.dSYM`, uncaught exceptions on aarch64                                                       | `6c9ae46094`, `69b2aca9f5`, `3fc6a23bd5`, `9f51b0b2d5`, `6b82ffcf7a`, `7cb5c65c69`; test `3e6235059b`                                                                                          | TC18, TC19, TC21, TC22                                                       | none                                                                                                                                                                                        | `ready`      |
| UL18 | Runtime fixes: collections out of `createLowLevelThread`, `importc.h` under clang, vcruntime                | [`5d81911f60`](https://github.com/PetarKirov/ldc/commit/5d81911f60c38c90487afd21fc3f3b04da7222bc), `24b7022427`, `e41ee91cc1`, `ff472ff2c8`; tests `1e8f386e3e`                                | TC8, TC11, the Windows cross-build                                           | none                                                                                                                                                                                        | `ready`      |
| UL19 | Phobos submodule on PetarKirov/phobos (time zones under a `TZDIR` without a trailing slash)                 | [`860cbe231d`](https://github.com/PetarKirov/ldc/commit/860cbe231df8ea2f496fb3edd8336e1a644ce046)                                                                                              | TC22 (`std.datetime.timezone` runs)                                          | see UP1                                                                                                                                                                                     | `superseded` |
| UL20 | A `scope` lazy variadic array of delegates needs no closure                                                 | [`0c89869f30`](https://github.com/PetarKirov/ldc/commit/0c89869f3013acec8e22b7ee7f762e699698856c)                                                                                              | As UD8                                                                       | upstream as UD8, reaching LDC through a frontend merge                                                                                                                                      | `blocked`    |
| UL21 | A closure's captures after a plain local still escape (no `scope` inferred for them)                        | [`c5b18c33b1`](https://github.com/PetarKirov/ldc/commit/c5b18c33b115950555725376679c2b6373e9bdc9); test parity `873265a00b`                                                                    | `sparkles:test-harness` `benchCase` (O14), any template registering closures | [dlang/dmd#24243](https://github.com/dlang/dmd/pull/24243) merged (fixes [#24065](https://github.com/dlang/dmd/issues/24065)), not yet in LDC master                                        | `superseded` |
| UL22 | ImportC: a member of an all-default compound literal of a zero-initialized struct (`f((W){ { } }.wrapped)`) | none: to fix in `gen/llvmhelpers.cpp` `DtoSymbolAddress`                                                                                                                                       | Clay's `CLAY(id, { })` through ImportC (worked around in the UI bench)       | none; DMD compiles it                                                                                                                                                                       | `needs-work` |

UL2 and UL3 are blocked on UL1 and on the LLVM entries UV1–UV2. UL14 is
blocked on LDC adopting LLVM 24, and UL15 on UL14. UL6, UL9 and UL20 change
the DMD frontend, so they are proposed to dlang/dmd and reach LDC with its
next frontend merge; the fork drops them then. UL7, UL8, UL16 and UL21 are
dropped at the next rebase onto a frontend that has their upstream fixes.

UL21 is the frontend bug behind `benchCase`'s use-after-return (test-runner
O14): `checkAssignEscape` stopped at the first variable a closure captures
that is neither `ref` nor `scope`, so the parameters it captured after a
plain local stayed inferable as `scope`. It is not LDC-specific: DMD 2.112.1
has it too, and DMD master, so the shell's DMD, has the fix. The reduction is
LDC's `tests/dmd/runnable/issue24065b.d`.

UL22 fails with "no init symbol for zero-initialized struct": the frontend
folds `(W){ { } }` to `W.init` and reads `.wrapped` through it, and LDC emits
no init symbol for a zero-initialized struct. The reduction:

```c
typedef struct { int a; } Inner;
typedef struct { Inner wrapped; } W;
void g(Inner i);
void h(void) { g((W){ { } }.wrapped); }
```

The fix is to materialize a zeroed temporary for the lvalue there; it needs
an LDC regression test and a full suite run, so it waits for the next LDC
change rather than taking a toolchain bump of its own.

## 5. LLVM and Phobos

[PetarKirov/llvm-project `sparkles/main`](https://github.com/PetarKirov/llvm-project/compare/c7a69e6fc6d40c220f58487039f05fe6b9f5d16c...019489a268bec85a95a7298283476cfdbf0c04fc)
is LLVM main with 32 commits. The fork review covers 31 of them with
their tests. No commit has been proposed by the fork, and the fork has no
`fix/*` branches.

| ID  | Change                                                                           | Commits                                                                                                                                                                                                                                      | Needed by                          | Upstream                                                                                                | State      |
| --- | -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------- | ---------- |
| UV1 | SPIR-V PhysicalStorageBuffer addressing and struct block wrapping for Vulkan     | [`88d6cd00e5`](https://github.com/PetarKirov/llvm-project/commit/88d6cd00e597b9bc0bde0d2894c6ac7b8ccef933) (Pham Quang Ha's)                                                                                                                 | SHT1                               | [llvm/llvm-project#216919](https://github.com/llvm/llvm-project/pull/216919) open                       | `proposed` |
| UV2 | The six SPIR-V changes SHT1 names, in its order                                  | `7c6f682594`, `391bbed1a8`, `3592f59866` (amends UV1), `7ed8c4cae2`, `211a3ab07d`, `340fd88de7`                                                                                                                                              | SHT1                               | none; the module flag and metadata of `7c6f682594` need agreement                                       | `blocked`  |
| UV3 | Further SPIR-V lowering for the shader interfaces                                | `fd8b2594fd`, `c8cd35917d`, `a179f26f88`, `929b6bb879`, `9fcf796e56`, `cefc4ed81e`, `d56b7d97a2`, `06866a48d3`, `b62852ae29`, `7578d189eb`, `ba75a9aa72`, `1de563895a`, `70b51b6381`, `d6e24f6100`, `c9dd5124e6`, `ce3d2ec16f`, `4e59be36e8` | The shader specifications          | none                                                                                                    | `ready`    |
| UV4 | GVN forwards a vector element as an `extractelement`                             | `41ccb17558`                                                                                                                                                                                                                                 | Shader code generation             | none                                                                                                    | `ready`    |
| UV5 | SelectionDAG falls back on `sin` and `cos` without an `FSINCOS` libcall (`f128`) | `1d775759c7`                                                                                                                                                                                                                                 | Quadruple-precision `real` (TCW11) | none                                                                                                    | `ready`    |
| UV6 | Debug info for an enumeration based on an enumeration                            | `e31c11bf0b`                                                                                                                                                                                                                                 | With LDC's `1cd64184fe` (UL14)     | none                                                                                                    | `ready`    |
| UV7 | libunwind, libc++ and wasm-ld for WASI                                           | `2d833c467d`, `739a6c7943`, `54d4be7f9f`, `275dcf2887`                                                                                                                                                                                       | TCW1, TC18; tech debt WTD36        | `2d833c467d` matches [llvm/llvm-project#168449](https://github.com/llvm/llvm-project/pull/168449), open | `ready`    |
| UV8 | Clear the target lowering's used set per module (reproducible objects)           | [`019489a268`](https://github.com/PetarKirov/llvm-project/commit/019489a268bec85a95a7298283476cfdbf0c04fc)                                                                                                                                   | TC15                               | none                                                                                                    | `ready`    |

UV2 is blocked on UV1. UV8 is not yet in the fork review.

PetarKirov/phobos carries one commit,
[`36f227da93`](https://github.com/PetarKirov/phobos/commit/36f227da93e6ad8115ef8af13e1df008c631b6a6),
which LDC's Phobos submodule points at (UL19):

| ID  | Change                                                                       | Upstream                                                                                                                               | State        |
| --- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| UP1 | `std.datetime.timezone` names zones under a `TZDIR` without a trailing slash | [dlang/phobos#11011](https://github.com/dlang/phobos/pull/11011) merged, fixing [#11000](https://github.com/dlang/phobos/issues/11000) | `superseded` |

UP1 and UL19 close together. The submodule goes back to
ldc-developers/phobos once LDC's Phobos contains dlang/phobos#11011, and
`std.datetime.timezone`'s unittests pass on it.

## 6. dlang.nix

[PetarKirov/dlang.nix `feat/ldc-sparkles`](https://github.com/PetarKirov/dlang.nix/commit/3f629c49a0380508923bd45100987a895e92f61c)
is dlang.nix's `main` with the toolchain packages: `ldc-vulkan` and
`ldc-sparkles`, `llvm-spirv-vulkan`, `clang-sparkles`, `lld-sparkles`,
`ldc-android`, the WASI sysroots and runtimes, `dmd-sparkles`, and their
tests. The same owner maintains dlang.nix, so the branch is upstreamed by
merging it into `main`.

| ID  | Change                                                                     | Needed by                                                       | State       |
| --- | -------------------------------------------------------------------------- | --------------------------------------------------------------- | ----------- |
| UN1 | The toolchain packages and the tests Nix runs for them                     | TC1–TC24, TCW1–TCW11                                            | `blocked`   |
| UN2 | DMD 2.112 patched for time traces (`4ef5441`) and large writes (`7bf1b17`) | Nothing: `dmd-sparkles` replaced DMD 2.112 as the shell's `dmd` | `fork-only` |

UN1 waits on TCD2: it is proposed together with the fork commits it builds.
UN2 is removed once nothing in Sparkles or dlang.nix builds DMD 2.112.

## 7. Order and blockers

Five chains decide the order:

1. **Shaders.** UV1 → UV2 → UL1 → UL2, UL3, UL4. Two pull requests by
   another author, llvm/llvm-project#216919 and ldc-developers/ldc#5132,
   block the whole chain. UV3 and UV4 can be proposed before UV1 lands.
2. **DMD frontend first.** UD3, UD8 and UD9 go to dlang/dmd, UD10 before
   UD8 so that UD8's test can run under `-inline` (on `fix/scope-lazy-variadic`
   it keeps `-inline` out of its permutations until then); their LDC
   copies UL6, UL20 and UL5 are dropped with LDC's next frontend merge.
   UL9 needs its dlang/dmd form written first.
3. **Path mapping.** UD2 and UL10 implement the same option and are
   proposed together, so that the two compilers agree on its meaning.
4. **LLVM 24.** UL14 → UL15. LDC has to adopt LLVM 24 before the
   WebAssembly series can be proposed.
5. **Drops.** UD4, UL7, UL8, UL16, UL19, UL21 and UP1 leave the forks at their
   next rebase (TCU4).

The rest (UD1, UD5, UD6, UD7, UD10, UL12, UL13, UL17, UL18, UV5–UV8, and
US2, US4–US10) waits only on TCD2 and, for the LDC and LLVM entries, on its
`fix/*` branch. UD11 is a report to file. UL22 is a fix still to write.

UD11 is a DMD glue bug found with UD10 and not fixed: a `ref` function that
returns a call's `ref` result through a temporary with a destructor returns
the address of a stack copy, because `elemIsLvalue` takes no `*call()` for an
lvalue (for a struct returned through a hidden pointer it may point into a
temporary being destroyed). Report text in §8.

## 8. Reports to file

**UD8 pull request** (from `fix/scope-lazy-variadic`; title "Fix #22885 -
a `scope` lazy variadic array needs no closure"). The body is §2.1. The tests
are runnable/test22885.d (semantics, evaluation order and count, struct
temporaries, exceptions, deep recursion, zero allocations by `GC.stats`, a
non-`scope` closure still correct after its frame is gone); runnable/test22885b.d
(`-betterC`); compilable/test22885.d (call shapes, mangling, CTFE); and
fail_compilation/test22885.d, test22885b.d and test22885c.d (escapes, override,
a non-`scope` array still allocates).

**UD10 issue** (dlang/dmd; no existing issue found). Title: "Reading a field
of a temporary reads it after the temporary's destructor". Body:

```d
struct T { int v; ~this() { v = -1; } int get() { return v; } }
int f() { return T(9).v; }           // -1
int g() { return T(9).get; }         // -1 with -inline
int dg(int delegate() d) { return d(); }
int lz(lazy int x) { return x; }
void main()
{
    assert(f() == 9);
    assert(dg(() => T(9).get) == 9); // -1 with -inline
    assert(lz(T(9).get) == 9);       // -1 with -inline
}
```

The value of a full expression is read after its temporaries are destroyed
whenever that value is an lvalue: the glue's `appendDtors` takes the
lvalue's address, runs the destructors, then reads through it. `-inline`
turns any member call on a temporary into that form, so delegate literals
and `lazy` arguments hit it too. LDC is correct.

**UD10 pull request** (from `fix/temporary-lvalue-dtor`; title "Fix #(the UD10 issue) -
read a full expression's value before destroying its temporaries"). Only a
`ref` return and an RVO return through the hidden pointer need the lvalue;
`toElemDtor` now says so, and every other caller gets the value copied before
the destructors run, as a non-lvalue result already was. Test:
`runnable/dtor_temp_lvalue.d` (field, member call, a static array field,
delegate literal, `lazy` once and twice, a condition, a `ref` return that
still returns the variable itself), under the default permutations.

**UD11 issue** (dlang/dmd; no existing issue found). Title: "`ref` return of
a call's `ref` result through a temporary returns a stack copy":

```d
int g = 5;
struct Bump { int* p; ~this() { *p = 99; } ref int get() { return *p; } }
ref int r() { return Bump(&g).get; }
void main() { assert(&r() is &g); } // fails: the address of a copy
```
