# Cross-Language DAGs (Theme)

One graph, many compilers. A cross-language build is an ordinary file graph whose
edges cross a boundary where the artifact's _meaning_ changes: an IDL becomes
generated source, a C header becomes a Rust `extern` block, a host tool consumes
a target artifact. This page follows those three boundaries through the systems
that publish how they handle them, and separates the edges an engine can see from
the conventions it merely hopes hold.

**Last reviewed:** November 2, 2026

| Field      | Value                                                                                                                                  |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Category   | Theme — cross-cutting; no single system                                                                                                |
| Question   | Where does a multi-language build put its edges, what checks them, and which glue does no engine model?                                |
| Mechanisms | plugin protocols (`protoc-gen-*`), code generators (`cxxbridge`, `bindgen`), aspects, toolchains, platforms, configuration transitions |
| Systems    | Protocol Buffers, Bazel, Buck2, GN, Meson, Zig, `cxx`, `bindgen`, D ImportC                                                            |
| Vocabulary | [concepts] — _task description_, _scheduler_, _trace_ and _early cutoff_ are used as defined there, not redefined here                 |

**Built from (in-corpus):** [concepts] (the task-description framing),
[compile-time-execution] (`build.rs`, proc macros, host/target split),
[link-time-pruning] (the link as the coarsest node; ThinLTO's `1 + N` split),
[dependency-pruning] (strict deps; `proto_library` is an instance),
[semantic-caching] (what a key may ignore), [dynamic-deps-distributed] (a
discovered edge must become an artifact), [bazel], [buck2], [gn], [meson].

## Overview

### What it solves

Every engine in this catalog was designed around one compiler and one artifact
kind. A cross-language tree breaks both assumptions: the unit of work is no
longer "compile a translation unit", and the file carrying the contract between
two languages is often generated, sometimes by a tool written in a third
language, and always consumed under a different ABI. Three edges result:

1. **Schema → N languages.** One `.proto` fans out into C++, Java, Python, Rust
   and more, multiplying the graph by language count without an input changing.
2. **Source → foreign ABI.** A C header or a Rust `#[cxx::bridge]` declares
   functions and layouts two compilers must agree on; nothing in the file graph
   states the agreement.
3. **Host → target configuration.** Generator, compiler and binary can each need
   a different machine — the platform axis, the only one an engine models.

### Design philosophy

The systems agree on one principle — **make the boundary a file with a stable,
language-neutral description** — and disagree on how much of it to check.
Protocol Buffers' extension point is textual and process-shaped:

> "A plugin is just a program that reads a CodeGeneratorRequest from stdin and
> writes a CodeGeneratorResponse to stdout."
>
> — `protobuf/compiler/plugin.proto` ([plugin.proto][protobuf-plugin-proto])

`cxx` instead makes the bridge the source of truth, and states the header's job
precisely:

> "Our code generators don't read it but it gets `#include`'d and used in static
> assertions to ensure our picture of the FFI boundary is accurate."
>
> — `cxx` book, [Core concepts][cxx-concepts]

That sentence is the theme in miniature: the graph edge is the generated `.cc`,
the _check_ is a compile-time assertion in the consumer, and the generator's model
of the boundary is only as good as that assertion. `bindgen` is the third
position — derive the foreign side from the real header — and admits where it
stops: "We don't know which monomorphizations exist, and can't create new ones
because we aren't a C++ compiler" ([bindgen-cpp]).

## How it works — the three kinds of edge

### 1. Schema → N languages: the protobuf plugin protocol

`protoc` parses the schema once and hands each generator a
`CodeGeneratorRequest` whose `proto_file` field carries the whole import closure
"in topological order, so each file appears before any file that imports it"
([plugin.proto][protobuf-plugin-proto]). Each output directive gets its own
generator — built into `protoc`, or spawned as a `protoc-gen-*` plugin.

Two protocol properties shape every downstream graph. **Output names are the
generator's choice**: `File.name` is optional and arbitrary ("If the name is
omitted, the content will be appended to the previous file"), and
`insertion_point` lets one generator edit another's output. **The request is the
closure, not one file**, which is why a plugin can emit code referencing imported
types without a second pass.

Bazel turns that into a two-layer graph. `proto_library` publishes `ProtoInfo`
(descriptor sets plus import paths); a language rule attaches an **aspect** over
`deps`, and the aspect calls `proto_common.compile` with the language's
`proto_lang_toolchain` — in `protobuf`'s own rules literally
`cc_proto_aspect = aspect(implementation = _aspect_impl, attr_aspects = ["deps"],
…)` ([`cc_proto_library.bzl`][protobuf-cc-aspect]), so every `proto_library` in
the chain gets its own per-language action. The toolchain carries the glue as
data: `plugin` becomes `--plugin=protoc-gen-…=<executable>`, and `runtime` is "a
language-specific library that the generated code is compiled against. The exact
behavior is LANG_proto_library-specific" ([Bazel protocol-buffer
rules][bazel-proto-doc]) — which is why that page warns "Normally you should not
write those kind of rules unless you want to tune your Java compiler."

**Granularity.** `proto_common.compile` builds one `actions.run` whose arguments
are all of `proto_info.direct_sources`, whose `inputs` are the transitive proto
sources, and whose `outputs` are the generated files declared by convention —
`declare_generated_files` is documented "Use this in lang_proto_library-es when
protocol compiler generates files that correspond to `.proto` file names"
([`proto_common.bzl`][protobuf-proto-common]) — because the protocol permits
arbitrary names. So the action is **per `proto_library` per language**, not per
`.proto` file. **Catalog inference:** an edit to any direct source, or to any
imported proto, re-runs the generator for every direct source of that library,
and early cutoff fires only if the emitted bytes are unchanged; per-file actions
would require knowing the plugin's output mapping in advance.

Two side channels use the same IDL. `proto_library` exposes transitive descriptor
sets, and `proto_descriptor_set` concatenates them with a `file_concat` action
into one `FileDescriptorSet` ([`proto_descriptor_set.bzl`][protobuf-descriptor-set]),
so a reflection consumer need not run `protoc`. With `--strict_proto_deps`,
`proto_library` passes `--direct_dependencies` built from its own sources plus
its direct deps' export sets ([`proto_library_rule.bzl`][protobuf-proto-library-rule])
— the discipline [dependency-pruning] describes for Java and C++.

### 2. Foreign ABI: `bindgen` snapshots and `cxx` bridges

The FFI edge has no neutral description language, so each tool invents one.
**`bindgen` reads the header and writes Rust.** It "leverages `libclang` to
preprocess, parse, and type check C and C++ header files"
([Requirements][bindgen-requirements]), so its fidelity is exactly Clang's. For
C++ the book is explicit that this is a subset — inheritance and overloads mostly
work, templates only "without specialization", anything untranslatable becomes
"an opaque blob of bytes" — with one promise: "we should always get layout, size,
and alignment correct" ([bindgen-cpp]). Allowlisting exists because "the header
file contains C++ features for which Rust does not have a corresponding form
(such as partial template specialization)" ([Allowlisting][bindgen-allowlisting]).

**`cxx` writes both sides from one declaration.** The `#[cxx::bridge]` macro
expands during normal Rust compilation (the Rust half is inside the crate's own
compile), while the C++ half is a separate artifact produced by `cxxbridge`. The
book's "some other build system" page lists the minimum the integrator must do,
then declines to help with the middle step: "Produce the CXX-generated C++ bindings
code. Compile the generated C++ code. Link the resulting objects together with
your other C++ and Rust objects." … "Compiling C++ — However you like. We can
provide no guidance." ([Some other build system][cxx-other]). The generator owns
the _declaration_; the integrator owns the _compilation and link_.

### 3. Configuration: platforms, toolchains, transitions

The one boundary every engine models is the machine boundary, because a generator
is a host tool and its output is a target artifact. Bazel names three roles —
"Host", "Execution" and "Target" — and notes that "Builds only have one host
platform, but often have multiple execution and target platforms"
([Platforms][bazel-platforms]). Toolchain resolution picks a concrete toolchain
and execution platform per target, and `cfg` decides which configuration a
toolchain's dependency is built in:

> "The system libraries must be built for the same target platform as the final
> artifact, while the compiler must be runnable on the execution platform."
>
> — Bazel, [Toolchains][bazel-toolchains]

The same page's "toolchain transition" forces a resolved toolchain onto the
parent's execution platform, so a host tool is never built for the target.
**Catalog inference:** that is what makes a cross-language edge expressible — the
codegen tool and the code it generates are the same edge under two `cfg`s.

Buck2 says the quiet part: "Build configurations are also sometimes called
'platforms'. While technically separate, those two concepts are almost
identical" ([Configurations][buck2-configurations]). A configuration is a
constraint/value set hashed into output paths ("hashed buck-out"), and
**transitions** change it along an edge; one may "Return a blank configuration
with no constraints at all (useful to deduplicate work when actions produce
identical outputs, such as when downloading artifacts)"
([Configuration transitions][buck2-transitions]). Bazel prices the mechanism:
transitions bring "larger build graphs, less comprehensible build graphs, and
slower builds" ([Configurations][bazel-config]) — a cost that multiplies with
language count.

| System | Configuration key                           | Cross-compile input                               | Per-language toolchain                           |
| ------ | ------------------------------------------- | ------------------------------------------------- | ------------------------------------------------ |
| Bazel  | build settings + platform constraints       | `--platforms`, `register_execution_platforms`     | `toolchain()` + `proto_lang_toolchain`           |
| Buck2  | constraint/value set, hashed into outputs   | `--target-platforms`, `build.execution_platforms` | `is_toolchain_rule` rules in the toolchains cell |
| GN     | `(target_os, target_cpu)` × toolchain label | `gn gen --args='target_os=… target_cpu=…'`        | `toolchain()` with named `tool`s                 |
| Meson  | cross file (`[binaries]`, `[host_machine]`) | `--cross-file`, `exe_wrapper`                     | one compiler entry per language                  |
| Zig    | `std.Target.Query`                          | `-Dtarget=<arch>-<os>-<abi>`                      | none — one compiler, bundled libc                |

GN makes the second axis explicit in the label:
`//base/test:test_support(//build/toolchain/win:msvc)`, where a BUILD file "is
executed once for each toolchain it is referenced in"
([GN reference][gn-reference]), and `current_cpu` rather than `target_cpu` is
what a rule should read ([GN cross-compiling][gn-cross]). Meson keeps one global
cross file and therefore needs an escape hatch for host tools:
`exe_wrapper = 'wine64'` ([Cross compilation][meson-cross]). Zig removes the file
— the target is a query string parsed by `standardTargetOptions`, whose
`-Dtarget` option is "The CPU architecture, OS, and ABI to build for"
([`Build.zig`][zig-build]).

## Where glue remains manual

Every one of the following is a place a build can go green while the program is
wrong.

1. **Generator and runtime versions must be locked together.** `cxx`: "The
   version number of `cxxbridge-cmd` used for the C++ side of the binding must
   always be identical to the version number of `cxx` used for the Rust side"
   ([Bazel/Buck2][cxx-bazel]), and the halves "must always be created using the
   same release of CXX" ([cxx-other]). `protobuf` makes the runtime a toolchain
   attribute, but its behaviour is "`LANG_proto_library`-specific"
   ([bazel-proto-doc]). It is a manifest pin, not an edge. **Catalog inference:**
   a mismatched pair is a link error at best and silent ABI drift at worst.
2. **Output naming is a convention, not a contract.** Because a plugin may emit
   any `File.name`, `declare_generated_files` assumes one output per input with a
   substituted extension ([protobuf-proto-common]). A
   generator that emits a variable number of files, or names them from message
   names, forces either a coarse action or a hand-written rule.
3. **The generator needs the _same_ flags as the C build.** `bindgen` runs
   Clang, so it must be given the include paths, `-D` defines and `-std` the C
   build uses (C++ mode needs `clang_args(["-x", "c++"])`, [bindgen-cpp]); the
   binding action's key must cover them or a define change silently reuses old
   bindings. `cxx`'s Cargo path is weaker: the C++ compile happens inside
   `build.rs`, and change detection is whatever the script declares — "By default
   without any `rerun-if-changed`, Cargo will re-execute the build script after
   _any_ file changed in the project" ([Cargo][cxx-cargo]). The whole C++ subgraph
   is one Cargo node; [compile-time-execution] covers that position in full.
4. **Only one of the two tools checks the boundary.** `cxx`'s static assertions
   make the C++ compiler verify the generator's model ([cxx-concepts]); `bindgen`
   has no equivalent, so the check is the programmer's. **Catalog inference:** a
   node comparing the two compilers' layouts would be the missing piece.
5. **The link is the only place the ABIs meet.** One link action consumes objects
   from every language's toolchain, which is why [link-time-pruning] calls it "the
   build graph's coarsest task". Rebuilds suffer at the boundary: link targets
   "always relink when any transitive rlib changed because rlibs aren't
   byte-stable under `-C incremental`" ([link-time-pruning], quoting
   [nix-cargo-unit]). ThinLTO splits one link into an index step plus one backend
   per module, with per-module inputs discovered from an imports file
   ([link-time-pruning] §5); cross-_language_ LTO needs flags at both compilers
   that the graph does not model (**catalog inference**). Runtime semantics are
   outside every engine too: `cxx` makes the integrator assert thread safety by
   hand, because generated types "do not come with `Send` and `Sync` impls"
   ([`extern "C++"`][cxx-extern-cpp]).

## Analysis spine

| Dimension                      | Protobuf (Bazel)                                         | `bindgen`                       | `cxx`                                              | Platforms/transitions                   |
| ------------------------------ | -------------------------------------------------------- | ------------------------------- | -------------------------------------------------- | --------------------------------------- |
| Boundary artifact              | `CodeGeneratorRequest` → `File` entries                  | generated `bindings.rs`         | generated `.h` + `.cc`; Rust half in the crate     | the configuration itself                |
| Fan-out                        | one schema → one action per language per `proto_library` | one header → one module         | one bridge → one header + one source               | one target → one node per configuration |
| Who checks the contract        | `protoc` + the consumer's compiler                       | `libclang` at generation time   | C++ compile-time static assertions                 | toolchain resolution                    |
| Incremental granularity        | per `proto_library` × language; transitive proto inputs  | whole header, whole binding     | whole bridge; per-file if the integrator splits it | per configured target                   |
| Failure if the check is absent | wrong generated code, caught downstream                  | layout/ABI mismatch at run time | a static assertion fails — the good case           | a host tool built for the target        |

A schema boundary is checked twice (by `protoc`, then the consumer's compiler);
an FFI boundary once (`cxx`) or not at all (`bindgen`); a configuration boundary
is checked by the engine, but only for _placement_, never for semantics. Two
failures follow. **The boundary is a convention**: the graph holds only the
generated artifact, and `cxx`'s assertion lives inside the consumer's compile, so
a build that skips that compile (a Rust-only test, a cached artifact) skips the
check. **Granularity is set by the generator's output naming**: the coarse
protobuf action is a throughput bug that scales with schema count, not a
correctness one ([semantic-caching] is the general treatment).

## Strengths

- **A neutral IDL is the only boundary that scales to N languages**, and it gives
  a second consumer (descriptor sets) for free.
- **Toolchains make the per-language glue data**, so a new language is a new
  toolchain rather than a new engine feature.
- **The platform triad covers every cross-language edge**, because a generator is
  always a host tool.

## Weaknesses

- **The checks are uneven**: schema boundaries twice, `cxx` once, `bindgen` not
  at all, the link never.
- **Granularity is inherited from the generator**, and version locking is a
  manifest convention — both invisible to the graph.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                        | Trade-off                                                          |
| ---------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------ |
| Text/process plugin protocol (`protoc-gen-*`)              | Any language can implement a generator; no linking into `protoc` | Arbitrary output names defeat per-file action granularity          |
| Request carries the whole import closure                   | Generators need imported types without a second pass             | One action's inputs are the transitive schema, so edits ripple     |
| Aspect per language over `deps` (Bazel)                    | One `proto_library` feeds every language without duplication     | Each language adds an action per library; the graph multiplies     |
| Per-language `proto_lang_toolchain`                        | Glue (plugin, flags, runtime) is data, not engine code           | Behaviour is `LANG_proto_library`-specific — a bespoke rule each   |
| Generate the foreign side from the real header (`bindgen`) | No hand-written declarations; layout from the compiler           | Only a subset of C++; requires the C build's exact flags           |
| Generate both sides from one declaration (`cxx`)           | One source of truth; static assertions check it                  | Version-locked tool; C++ compile and link are the integrator's job |
| Configuration transition on a toolchain (`cfg`)            | Host tools and target artifacts share an edge                    | Graph grows with configurations; documented memory and time cost   |

## Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG with `TaskNode` and
`TaskEdge`; `EdgeReason` names `packageDependency`, `planning`, `reduction`,
`publication` and four more, but nothing like "a generator produced this input"
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`). The repo's cross-language edge therefore lives
outside the DAG, in dub's hook:

```sdl
configuration "gpu-effects" {
    targetType "library"
    stringImportPaths "generated/shaders"
    preGenerateCommands "$DUB run --temp-build -q --root=$PACKAGE_DIR/../../apps/shader-compile -- --package=$PACKAGE_DIR --out=$PACKAGE_DIR/generated/shaders --if-stale"
}
```

([`libs/ui/dub.sdl`][sparkles-ui-dub]) — D `@compute` sources in
`effect_shaders.d` are compiled by `apps/shader-compile` through LDC's Vulkan
target to SPIR-V, then `spirv-cross` to GLSL 330 and ES 100, then checked by
`glslang` ([`apps/shader-compile/dub.sdl`][sparkles-shader-compile-dub]). Three
compilers and a proving step sit inside one pre-build command, and freshness is a
stamp (`--if-stale`), not a key: the "one opaque node" position of
[compile-time-execution] with a cross-language payload.

- **Give the edge a name before giving it a key.** A `codegen` `EdgeReason` whose
  dependent's inputs are the `stringImportPaths` would make the shader edge
  visible to a dry run and to a future store; today only the hook knows it.
- **Prefer the compiler-checked boundary.** `sparkles:ghostty` binds C through
  ImportC, where "The D compiler parses the **real C header**, so struct layout,
  enum values, and function signatures can never drift from the upstream
  library. There is no `dstep`/`ctod` regeneration step to keep in sync"
  ([ImportC guide][importc-guide]) — `cxx`'s static-assertion idea taken to its
  conclusion. The flags still come from `pkg-config`, so the key must cover the
  `.pc` output and the pinned header version.
- **Keep generator and consumer versions in one pin**, and do not model
  cross-compilation as a `platform=` dflag: dub's per-platform `dflags` select
  flags, but they do not split exec from target (Bazel's `cfg = "exec"` versus
  `"target"`).

## Sources

Primary sources, opened at these pinned revisions:

- Protocol Buffers `5a89c084a0c055b21804acd8eae5bfc8e5ba9e28`:
  [`plugin.proto`][protobuf-plugin-proto],
  [`proto_common.bzl`][protobuf-proto-common],
  [`proto_library_rule.bzl`][protobuf-proto-library-rule],
  [`cc_proto_library.bzl`][protobuf-cc-aspect],
  [`proto_descriptor_set.bzl`][protobuf-descriptor-set].
- Bazel `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`:
  [`platforms.mdx`][bazel-platforms], [`toolchains.mdx`][bazel-toolchains],
  [`config.mdx`][bazel-config], [`protocol-buffer.mdx`][bazel-proto-doc].
- Buck2 `08b403b138373f506de90d15370162677526e388`:
  [`configurations.md`][buck2-configurations], [`transitions.md`][buck2-transitions].
- GN `ed7fee04cb30b96ed40ef188acfad5417349e399`:
  [`reference.md`][gn-reference], [`cross_compiles.md`][gn-cross]. Meson
  `27f69b22e5fe403d3ec5788216adaa85046d0e8f`: [`Cross-compilation.md`][meson-cross].
  Zig `8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d`: [`Build.zig`][zig-build].
- `cxx` `5d7705d7fc78ec811ca97527a9c151bd3d9c7b95`:
  [`concepts.md`][cxx-concepts], [`bazel.md`][cxx-bazel], [`cargo.md`][cxx-cargo],
  [`other.md`][cxx-other], [`extern-c++.md`][cxx-extern-cpp].
- `bindgen` `bb8bd1b0211752477707f0084f92c2af526eba89`:
  [`requirements.md`][bindgen-requirements], [`cpp.md`][bindgen-cpp],
  [`allowlisting.md`][bindgen-allowlisting].

Unverified: no benchmark isolates the cost of coarse protobuf codegen actions,
and no published check compares two compilers' struct layouts; statements marked
**catalog inference** are analysis, not measurements.

<!-- References -->

[concepts]: ./concepts.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[gn]: ./gn.md
[meson]: ./meson.md
[compile-time-execution]: ./compile-time-execution.md
[link-time-pruning]: ./link-time-pruning.md
[dependency-pruning]: ./dependency-pruning.md
[semantic-caching]: ./semantic-caching.md
[dynamic-deps-distributed]: ./dynamic-deps-distributed.md
[nix-cargo-unit]: ./nix-cargo-unit.md
[importc-guide]: ../../guidelines/importc-c-libraries.md
[sparkles-ui-dub]: ../../../libs/ui/dub.sdl
[sparkles-shader-compile-dub]: ../../../apps/shader-compile/dub.sdl
[protobuf-plugin-proto]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/src/google/protobuf/compiler/plugin.proto
[protobuf-proto-common]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/bazel/common/proto_common.bzl
[protobuf-proto-library-rule]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/bazel/private/proto_library_rule.bzl
[protobuf-cc-aspect]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/bazel/private/oss/cc_proto_library.bzl
[protobuf-descriptor-set]: https://github.com/protocolbuffers/protobuf/blob/5a89c084a0c055b21804acd8eae5bfc8e5ba9e28/bazel/proto_descriptor_set.bzl
[bazel-platforms]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/concepts/platforms.mdx
[bazel-toolchains]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/extending/toolchains.mdx
[bazel-config]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/extending/config.mdx
[bazel-proto-doc]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/versions/9.1.0/reference/be/protocol-buffer.mdx
[buck2-configurations]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/concepts/configurations.md
[buck2-transitions]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/concepts/transitions.md
[gn-reference]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/docs/reference.md
[gn-cross]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/docs/cross_compiles.md
[meson-cross]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/docs/markdown/Cross-compilation.md
[zig-build]: https://github.com/ziglang/zig/blob/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/Build.zig
[cxx-concepts]: https://github.com/dtolnay/cxx/blob/5d7705d7fc78ec811ca97527a9c151bd3d9c7b95/book/src/concepts.md
[cxx-bazel]: https://github.com/dtolnay/cxx/blob/5d7705d7fc78ec811ca97527a9c151bd3d9c7b95/book/src/build/bazel.md
[cxx-cargo]: https://github.com/dtolnay/cxx/blob/5d7705d7fc78ec811ca97527a9c151bd3d9c7b95/book/src/build/cargo.md
[cxx-other]: https://github.com/dtolnay/cxx/blob/5d7705d7fc78ec811ca97527a9c151bd3d9c7b95/book/src/build/other.md
[cxx-extern-cpp]: https://github.com/dtolnay/cxx/blob/5d7705d7fc78ec811ca97527a9c151bd3d9c7b95/book/src/extern-c++.md
[bindgen-requirements]: https://github.com/rust-lang/rust-bindgen/blob/bb8bd1b0211752477707f0084f92c2af526eba89/book/src/requirements.md
[bindgen-cpp]: https://github.com/rust-lang/rust-bindgen/blob/bb8bd1b0211752477707f0084f92c2af526eba89/book/src/cpp.md
[bindgen-allowlisting]: https://github.com/rust-lang/rust-bindgen/blob/bb8bd1b0211752477707f0084f92c2af526eba89/book/src/allowlisting.md
