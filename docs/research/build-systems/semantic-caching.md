# Semantic Caching (Theme)

A cache key is a claim about what a task read. Most systems make the claim
maximally: hash every declared input, byte for byte, and accept that a comment
edit invalidates a downstream compile. This page is about the systems that hash
_less_ — a parsed interface, a stripped artifact, a manifest of the files a
tool actually opened — and when the smaller key is still true. It is not about
early cutoff, though the two are complements.

**Last reviewed:** November 3, 2026

| Field      | Value                                                                                                                         |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Category   | Theme — cross-cutting; no single system                                                                                       |
| Question   | When can a cache key hash a program's contract instead of its bytes, and what breaks when the projection is wrong?            |
| Mechanisms | AST/API hashing, interface artifacts (`ijar`, Turbine, export data, `.hi`), manifest indirection, normalization, `unihash`    |
| Systems    | Zinc/sbt, Go, Bazel (Java), ccache, BitBake, Sandstone/Nix, Pants, Buck2, Ninja                                               |
| Vocabulary | [concepts] — _early cutoff_, _verifying trace_ and _constructive trace_ are used as defined there, and are not redefined here |

## Overview

### What it solves

A key that is too strong costs throughput, not correctness — and at monorepo
scale throughput is the product. [concepts] §6 records the general form from
the à-la-carte experience: "Irrelevant differences kill sharing" — a compiler
path, a timestamp, a reordered flag list each cause a miss with no semantic
cause (JFP §7.4). Semantic caching attacks this one level up: instead of making
the environment look identical, it hashes what the consumer can actually
observe.

Early cutoff is a rebuilder property: recompute the consumer, notice its result
is equal, stop propagating ([concepts] §4; Bazel's change pruning, Buck2's
interned revisions, Ninja's `restat`, BitBake's `unihash`). A semantic key is a
property of the _key_: the consumer is never scheduled because the producer's
contract did not change — so it must be right without running anything.

### Design philosophy

> A key must cover the content of every artifact the consumer's toolchain
> actually reads — and an artifact is a safe boundary only if it carries
> everything the toolchain is allowed to observe.

ijar's README states the failure the mechanism exists to fix:

> "even a change that is insignificant to the compiler (such as the addition of
> a print statement to a method in a prerequisite class) will cause the jar to
> change, and any code that depends on this jar's interface will be recompiled
> unnecessarily."
>
> — Bazel [`third_party/ijar/README.txt`][ijar-readme]

The counter-discipline is Go's build-ID comment: "The content hash of every
input file for a given action must be included in the action ID hash"
([`buildid.go`][go-buildid]). Both hold at once because Go hashes a
dependency's **export data**, the artifact the compiler reads, not the object
file beside it: the rule is "hash what the consumer consumes".

## How it works — four ways to hash less

| Family             | Key computed from                             | Examples                                   | Boundary is                    |
| ------------------ | --------------------------------------------- | ------------------------------------------ | ------------------------------ |
| Interface hash     | parsed declarations                           | Zinc API hash, Zinc name hashes            | a data structure, no artifact  |
| Interface artifact | bytes of a stripped or specialised artifact   | `ijar`, Turbine, Go export data, GHC `.hi` | a real file the consumer reads |
| Manifest           | fast key, then a recorded list of real inputs | ccache direct mode, `go test` result cache | a discovered input list        |
| Normalization      | a canonicalised form of the same input        | ccache `-E`, `-trimpath`, path remapping   | the normaliser's semantics     |

An interface artifact is checked by the consumer's compiler; an interface hash
is checked by nobody, and its errors are silent.

### 1. Hash the AST: Zinc's API and name hashes

Zinc, the incremental Scala compiler sbt delegates to, computes the key from a
model of the source rather than from the source. A compiler phase extracts one
`ClassLike` API per class ([`API.scala`][zinc-api]); `HashAPI` hashes name,
annotations, modifiers, access and structure ([`HashAPI.scala`][zinc-hashapi]).
There is no body in the model to hash — `xsbti.api.Def` is a signature — so
implementation edits are invisible by construction.

The finer mechanism is **name hashing**: definitions are flattened, grouped by
simple name, and each group hashed independently.

> "NOTE: The hashing sum used for hashing a group of definition is insensitive
> to order of definitions."
>
> — Zinc [`NameHashing.scala`][zinc-namehashing]

Order-insensitivity is the AST-level analogue of format-insensitivity: moving a
method or reordering members cannot change a name hash. Per-name hashes live on
`AnalyzedClass`; an `ExtractUsedNames` pass records which names each source
mentions, and `NameHashFilteredInvalidator` invalidates only dependents whose
source used a changed name ([`MemberRefInvalidator.scala`][zinc-memberref]).

Zinc is also the most honest about where the model stops:

- `APIChangeDueToMacroDefinition` and `APIChangeDueToAnnotationDefinition`
  invalidate all member-reference dependents: both can change generated code
  without changing the signature.
- A change to implicit names invalidates unconditionally; a dependent that is
  not a Scala class skips the name filter entirely.

### 2. Hash the interface artifact: `ijar`, Turbine, export data, `.hi`

The artifact approach replaces a computed model with a file the consumer
compiles against. `ijar` post-processes a compiled jar into an interface jar,
discarding method code, private members, debug tables and every attribute not
needed to describe the class, and zeroes the jar's mtimes
([`README.txt`][ijar-readme]); its README reports 530 ms for a 42 MB jar of
5,878 classes, 50 ms typical.

Turbine does the same job from source, removing the dependency on a full javac
compilation having run:

> "Compiling the interface jar from source moves javac off the build's critical
> path."
>
> — Bazel [`JavaHeaderCompileAction.java`][bazel-header-action]

Bazel wires this in as two defaults, both `true`: `--use_ijars` ("This will
result in faster incremental compilation, but error messages can be different",
[`JavaOptions.java`][bazel-java-options]) and `--java_header_compilation`
("Compile ijars directly from source"). A dependent's `javac` reads the
dependency's header jar, so a change confined to method bodies never enters the
dependent's action key.

Go reaches the same place without a stripper. A build ID has the form
`actionID/contentID(export)/contentID(object)`, and `buildActionID` writes each
dependency as `import <path> <buildExportID>` — the **export data's** content
ID, not the object file's ([`exec.go`][go-exec], [`buildid.go`][go-buildid]).
The producer stamps its own output hashes into the build ID, so the consumer
reads them instead of re-hashing the file ([`buildid.go`][go-buildid]).

Sandstone carries the pattern into Nix: each GHC module is its own derivation
with separate content-addressed `object` and `interface` outputs, and dependents
consume `.hi`, so an implementation edit that leaves `.hi` unchanged presents
the same path ([sandstone] §2).

### 3. Hash a manifest: ccache direct mode and `go test`

Direct mode is a two-level lookup that keeps the first key cheap. The fast key
hashes the source, compiler options and common compiler identity; the cache then
retrieves a **manifest** holding the include paths, digests, sizes and mtimes
from the run that produced the result:

> "The current contents of the include files are then hashed and compared to the
> information in the manifest. If there is a match, ccache knows the result of
> the compilation."
>
> — ccache [`doc/manual.adoc`][ccache-manual]

The manifest lets a key cover inputs the build system never declared. `go test`
has the same shape: the first key is the test binary plus cacheable flags, and
the stored entry is the log of environment variables and files the test
consulted. The second key hashes their current values; `computeTestInputsID`
replays the log and hashes each `getenv`/`stat` entry ([`test.go`][go-test]).
The documented promise is explicitly semantic:

> "Tests that open files within the package's module or that consult environment
> variables only match future runs in which the files and environment variables
> are unchanged."
>
> — `go help test`, [`test.go`][go-test]

Dependency discovery is applied to the key rather than the graph: the first run
records, later runs verify.

Ccache's **depend mode** is the third point in this design space, between
direct and preprocessor modes. It never runs the preprocessor, even on a miss;
instead it reads include information from compiler-generated dependencies
(`-MD`/`-MMD`, or MSVC `/showIncludes`). That lowers miss overhead and suits
remote compilation, but makes the key more source/option-sensitive and
inherits depfile policy: `-MMD` omits system headers, so changes there are
ignored, while `-MD` or `/showIncludes` includes them and slows manifest
checking ([`doc/manual.adoc`][ccache-manual]). It is also the mode required
for ccache's limited Clang-module support: `module.modulemap` files are
hashed, Clang's binary module cache is ignored, standard C++20 modules are
explicitly unsupported, and explicit `-fmodule-file=` inputs are hashed. A
module system therefore moves the dependency boundary again — from text the
preprocessor expanded to binary artifacts the compiler selected — and a cache
that cannot enumerate those artifacts must either over-hash a directory or
refuse the compilation.

### 4. Normalize the input

The weakest family changes only how the input is spelled. ccache's
**preprocessor mode** hashes the output of `-E`: comments are gone, macros are
expanded, includes are resolved, so two sources differing only in comments or
formatting produce the same key. Direct mode is the fast path; preprocessor mode
is the canonical one it falls back to.

Path normalization is the other half. `-trimpath` folds the module path and
version into Go's action ID instead of the checkout directory
([`exec.go`][go-exec]); ccache's `base_dir` rewrites absolute paths under a
common prefix, and `hash_dir=false` drops the working directory
([`doc/manual.adoc`][ccache-manual]). These are not interface hashes — a
comment still changes a raw-source key — but they remove spurious differences.

A semantic key can always be replaced by "compute, then compare": BitBake's
`unihash` maps both input identities onto one output identity ([bitbake]),
Bazel resurrects dependents when a recomputed `SkyValue` is identical ([bazel]),
Pants compares values — "exact value equality, not a hash approximation"
([pants]), Buck2 re-finds an interned revision ([buck2]), and Ninja's `restat`
uses an unchanged mtime as a proxy for bytes ([ninja]). These complement the
key: it saves the recompute, equivalence repairs what it could not safely cover.

## Where the insensitivity comes from

| Change                        | Zinc                         | Go                                   | Bazel Java             | ccache                          | Nix            |
| ----------------------------- | ---------------------------- | ------------------------------------ | ---------------------- | ------------------------------- | -------------- |
| comment or whitespace         | invisible (AST)              | own package: new key; dependents: no | invisible (class file) | direct: miss; preprocessed: hit | new key        |
| private member                | invisible except trait cases | may change export data               | stripped by `ijar`     | new key                         | new key        |
| method body                   | invisible                    | export data changes → propagates     | stripped by `ijar`     | new key                         | new key        |
| parameter rename              | **new hash** (names hashed)  | export data changes                  | class file changes     | new key                         | new key        |
| new header shadows an include | n/a                          | n/a                                  | n/a                    | possibly missed (documented)    | n/a            |
| absolute path                 | analysis-relative            | `-trimpath` normalises               | mostly irrelevant      | `base_dir` / `hash_dir`         | store-path key |

"Semantic" is not one property: Zinc never sees the text, Bazel's `javac` erased
it before `ijar` sees the class file, ccache is insensitive only on its fallback
path, and Go only across a package boundary (**catalog inference** for the Go
row: the dependent's key uses the export-data content ID, and ordinary comments
are not represented in the compiler's IR). Even "comments do not matter" is
language-specific: build constraints, compiler directives, doc comments feeding
generated interfaces, annotations/macros, and `#line`-style mappings can all be
load-bearing. A semantic key is therefore a claim about a congruence relation
for one toolchain and one consumer, not a universal normal form.

## Correctness risks

### Under-approximation is a silent wrong answer

A key that hashes too little produces a cache hit whose artifact is stale. No
tool reports it; the build succeeds and the test passes against yesterday's
class file. Zinc's escape hatches are a catalogue of features that leak past a
signature — macros, annotation definitions, implicit search, trait-private
members.

`ijar` documents the hazard from the artifact side:

> "It's tempting to discard package-private classes and class members. However,
> this would be incorrect because they are a necessary part of the package
> interface, as a Java package is often compiled in multiple stages."
>
> — Bazel [`third_party/ijar/README.txt`][ijar-readme]

What counts as significant for compilation is defined by the compiler's
behaviour, not by visibility keywords. `static final` constants are the other
sharp edge — `javac` inlines compile-time constants, so the value is part of the
contract (**catalog inference** from Java's constant-expression rules). `ijar`
keeps "the minimal set necessary to describe the class interface", which is the
right phrase and the hard part.

Bazel's header pipeline adds a convention: only API-generating annotation
processors run during header compilation
([`JavaCompilationHelper.java`][bazel-header-helper]). A processor that
generates code without declaring itself API-generating falls outside the header
jar's model; the failure is a missing symbol at the consumer rather than a stale
hit — the safer direction, but proof that the boundary is a convention.

ccache states its own hole without euphemism:

> "There is a catch with the direct mode: header files that were used by the
> compiler are recorded, but header files that were _not_ used, but would have
> been used if they existed, are not."
>
> — ccache [`doc/manual.adoc`][ccache-manual]

The mitigation records whether `-I` directories existed at compile time; the
admission is that this "can't check with 100% accuracy" and is "safe to use in
the absolute majority of cases". A negative dependency — the absence of a file
— is the hardest thing to hash, and direct mode is the clearest example of a
semantic key that is probabilistic rather than exact.

Go's export data looks like a counter-example until one reads what it contains.
Unified IR writes function bodies into the export stream so the inliner can
re-run them ([`writer.go`][go-writer]); the export data is therefore not a
signature, and a body change that matters to inlining propagates. Go's
"interface" is the compiler's real cross-package contract, not the human-written
signature.

### Over-approximation is only a miss

The safe failure hashes too much. Zinc hashes parameter names
(`includeParamNames = true` in every `HashAPI` constructor), so renaming a
parameter changes a name hash though no call site's meaning changes
([`HashAPI.scala`][zinc-hashapi]). ccache hashes the compiler's size and mtime
by default; Go hashes the source bytes of the package being compiled, so a
comment edit in `foo.go` recompiles `foo` though it cannot change `foo`'s export
data. None is a correctness bug; all are hit-rate bugs, and hit rate is what
semantic caching buys.

**Catalog inference:** the parameter-rename consequence is not stated in Zinc's
documentation; it follows from `includeParamNames = true` plus the flag's
purpose of making the hash more precise. The hit-rate framing is analysis —
this page found no benchmark isolating API hashing from Zinc's other incremental
machinery.

### Contract, width and tool identity

Once a dependent compiles against an interface artifact, that artifact is an ABI
for the build. Bazel's `--use_ijars` text concedes the consequence: compilation
is faster, "but error messages can be different"
([`JavaOptions.java`][bazel-java-options]) — the switch is not
semantics-preserving for diagnostics, only for accepted programs. `ijar`'s
README ends with a TODO to canonicalise member order, dismissed because "we can
assume the compiler is deterministic" — interface artifacts inherit their
producer's determinism. Zinc instead compares classes with `SameAPI` rather
than with the 32-bit hash ([`APIs.scala`][zinc-apis]).

That width matters. Zinc's `HashAPI` uses a 32-bit `Int` (`type Hash = Int`,
`MurmurHash3.finalizeHash`), and `FileHash.hash` is the same width
([`HashAPI.scala`][zinc-hashapi]); Go uses SHA-256 ([`cache.go`][go-cache]);
ccache uses BLAKE3 with 160-bit digests ([`doc/manual.adoc`][ccache-manual]). A
collision in a 32-bit key is a false hit, and a false hit is a stale artifact —
**catalog inference:** the probability is a property of the width, not a
reported incident.

Tool identity must be in the key or a compiler upgrade reuses old outputs: Go
hashes a `toolID` ([`buildid.go`][go-buildid]), ccache records the compiler's
size and mtime unless `compiler_check` overrides it, and Zinc versions its
analysis format. ccache's default is itself weak — a same-size compiler with a
restored mtime is invisible (**catalog inference**).

## Strengths

- **Avoids work rather than discovering it was wasted**, and composes with a
  strong fallback: preprocessor mode, unconditional invalidation, raw hashes.
- **Makes the contract explicit** — `ijar`'s strip list, Zinc's `APIChange`
  cases and Go's export-data boundary are inspectable definitions.

## Weaknesses

- **Silent when wrong and extractor-specific**: a stale interface produces a
  green build, and keys rarely transfer across languages.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                        | Trade-off                                                                  |
| ------------------------------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Hash a parsed API instead of source bytes         | Comments, formatting and member order stop causing rebuilds      | The extractor becomes a second language model that can silently disagree   |
| Ship the interface as a real artifact             | The consumer's compiler checks it; misses are local              | An extra action and artifact per producer; the artifact becomes an ABI     |
| Key dependents on the consumed artifact's content | Exactly matches "what the consumer reads"                        | Producer must classify outputs by role (export vs object vs debug)         |
| Add a manifest for discovered inputs              | Covers undeclared headers without re-running discovery per hit   | Negative dependencies (absent files) cannot be recorded exactly            |
| Keep a strong fallback path                       | The weak key is an optimisation; correctness never depends on it | Two key materials to maintain and reconcile                                |
| Use a narrow hash for name groups                 | Cheap to store per class and per name                            | Collisions become stale artifacts; no system here documents detecting them |
| Invalidate unconditionally on macros/implicits    | Those features can change code without changing the visible API  | The optimisation disappears where programs are most dynamic                |

## Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG with no store and no
key: `TaskId` is a stable text identity derived from semantic segments
(`test:sparkles.base:unittest`), and `toHash` hashes that text, not any input
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`). There is nothing to weaken yet; the work is
choosing the first key correctly when a store arrives.

- **Start with the consumed artifact, not the produced one.** `TaskEdge` already
  distinguishes edges, but a key must name the content of what the consumer's
  tool reads. Go's `buildExportID` and Bazel's header jar are the proven shapes.
- **Prefer an artifact over a model.** An extractor in D would have to track
  every compiler feature that can change a module's contract — CTFE, `import`
  expressions, templates, `mixin`. Zinc's escape hatches are the cost of getting
  that wrong; a compiler-emitted artifact is checked by the compiler.
- **Never drop data from a key without naming the artifact that carries every
  observation.** Bazel's warning is the policy text: excluding data "later
  resulted in expensive debugging sessions and bug fixes" ([bazel] §4).
- **Add a manifest before adding tracing, and treat hash width as API.** A
  recorded input list verified once per hit beats a syscall layer for the
  `@nogc` world of [base]; a `size_t`-sized name hash is fine for a
  deduplication index, not for a correctness-critical key.

## Sources

In-corpus pages synthesized: [concepts] (grid, early cutoff, JFP §7.4), [sbt]
(Zinc's place and the two incrementality models), [bazel] (action keys, change
pruning, the warning against excluding data), [bitbake] (`unihash`),
[sandstone] (`object`/`interface` split), [buck2], [pants], [ninja] (non-hash
early cutoff), [perfect-dependencies], [build-maintenance], [dependency-pruning],
[sandboxing-overheads] (observation vs isolation), [nix-dynamic-derivations].

Primary sources, opened at these pinned revisions:

- Zinc `69c07a766fbb3781778bbd13a481864b656c0083`: [`API.scala`][zinc-api],
  [`HashAPI.scala`][zinc-hashapi], [`NameHashing.scala`][zinc-namehashing],
  [`APIs.scala`][zinc-apis], [`MemberRefInvalidator.scala`][zinc-memberref].
- Go `7b27665111926fad8dce05cff90616984acf9e81`: [`exec.go`][go-exec],
  [`buildid.go`][go-buildid], [`cache.go`][go-cache], [`test.go`][go-test],
  [`writer.go`][go-writer].
- ccache `d42cf23deddb2938591373daecf9bfaf65b487ad`: [`doc/manual.adoc`][ccache-manual],
  [`manifest.hpp`][ccache-manifest].
- Bazel `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`: [`third_party/ijar/README.txt`][ijar-readme],
  [`JavaHeaderCompileAction.java`][bazel-header-action], [`JavaOptions.java`][bazel-java-options],
  [`JavaCompilationHelper.java`][bazel-header-helper].

Unverified: no benchmark isolating API-hash hit rate was found for Zinc or sbt;
statements marked catalog inference are analysis, not measurements.

<!-- References -->

[concepts]: ./concepts.md
[sbt]: ./sbt.md
[bazel]: ./bazel.md
[bitbake]: ./bitbake.md
[sandstone]: ./sandstone.md
[buck2]: ./buck2.md
[pants]: ./pants.md
[ninja]: ./ninja.md
[perfect-dependencies]: ./perfect-dependencies.md
[build-maintenance]: ./build-maintenance.md
[dependency-pruning]: ./dependency-pruning.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[nix-dynamic-derivations]: ./nix-dynamic-derivations.md
[base]: ../../libs/base/index.md
[zinc-api]: https://github.com/sbt/zinc/blob/69c07a766fbb3781778bbd13a481864b656c0083/internal/compiler-bridge/src/main/scala/xsbt/API.scala
[zinc-hashapi]: https://github.com/sbt/zinc/blob/69c07a766fbb3781778bbd13a481864b656c0083/internal/zinc-apiinfo/src/main/scala/xsbt/api/HashAPI.scala
[zinc-namehashing]: https://github.com/sbt/zinc/blob/69c07a766fbb3781778bbd13a481864b656c0083/internal/zinc-apiinfo/src/main/scala/xsbt/api/NameHashing.scala
[zinc-apis]: https://github.com/sbt/zinc/blob/69c07a766fbb3781778bbd13a481864b656c0083/internal/zinc-core/src/main/scala/sbt/internal/inc/APIs.scala
[zinc-memberref]: https://github.com/sbt/zinc/blob/69c07a766fbb3781778bbd13a481864b656c0083/internal/zinc-core/src/main/scala/sbt/internal/inc/MemberRefInvalidator.scala
[go-exec]: https://github.com/golang/go/blob/7b27665111926fad8dce05cff90616984acf9e81/src/cmd/go/internal/work/exec.go
[go-buildid]: https://github.com/golang/go/blob/7b27665111926fad8dce05cff90616984acf9e81/src/cmd/go/internal/work/buildid.go
[go-cache]: https://github.com/golang/go/blob/7b27665111926fad8dce05cff90616984acf9e81/src/cmd/go/internal/cache/cache.go
[go-test]: https://github.com/golang/go/blob/7b27665111926fad8dce05cff90616984acf9e81/src/cmd/go/internal/test/test.go
[go-writer]: https://github.com/golang/go/blob/7b27665111926fad8dce05cff90616984acf9e81/src/cmd/compile/internal/noder/writer.go
[ccache-manual]: https://github.com/ccache/ccache/blob/d42cf23deddb2938591373daecf9bfaf65b487ad/doc/manual.adoc
[ccache-manifest]: https://github.com/ccache/ccache/blob/d42cf23deddb2938591373daecf9bfaf65b487ad/src/ccache/core/manifest.hpp
[ijar-readme]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/third_party/ijar/README.txt
[bazel-header-action]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/rules/java/JavaHeaderCompileAction.java
[bazel-java-options]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/rules/java/JavaOptions.java
[bazel-header-helper]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/rules/java/JavaCompilationHelper.java
