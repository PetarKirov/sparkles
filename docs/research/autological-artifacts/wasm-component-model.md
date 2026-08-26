# WebAssembly, WIT, and the component model (binary format / IDL / linking system)

A binary whose imports and exports are a **typed graph** rather than a symbol table — and which can hand that graph back as an interface-definition document with no external metadata, no debug info, and no registry lookup.

| Field           | Value                                                                                                                             |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Binary format + interface description language + linking model                                                                    |
| Language        | Specification (EBNF + Python reference ABI); reference tooling in Rust                                                            |
| License         | Apache-2.0 (spec repo); `wasm-tools` is Apache-2.0 / Apache-2.0-WITH-LLVM-exception / MIT                                         |
| Repository      | [WebAssembly/component-model][cm-repo] · [bytecodealliance/wasm-tools][wt-repo]                                                   |
| Documentation   | [Component Model Documentation][cm-book] · [Core spec: binary format][core-binary]                                                |
| First release   | Core Wasm 1.0 — W3C Recommendation 2019-12-05; component model shipped incrementally as WASI Developer Previews `0.2.0` → `0.3.1` |
| Axis profile    | Multiplicity **1** / Reflexivity **3** / Closure **2** / Mutability **0**                                                         |
| Index anchoring | **stream-scanned** — no offset table, no hash table, indices are positional                                                       |
| Dispatch owner  | **loader** (the embedding runtime, on an 8-byte preamble); never the kernel                                                       |

> **Latest release / revision surveyed:** `WebAssembly/component-model` at `4acb0dee` (2026-08-24), `bytecodealliance/wasm-tools` at `faf46729` (2026-08-25), `WebAssembly/tool-conventions` at `83e5d715`. All hands-on output below was produced with the `wasm-tools` **1.239.0** binary and Node **24.19.0** on 2026-08-26. **Platform:** format-level; every runtime that implements it.

---

## Overview

### What it solves

Core WebAssembly gives a module a genuinely _structural_ import/export list: every import is `(module, name, externtype)` and every export is `(name, externtype)`, where `externtype` is one of func/table/memory/global/tag with a full core type. That is already better than [ELF's `DT_NEEDED` plus `.dynsym`][elf-dynamic], which pairs a _filename_ with a flat list of _names_. But core Wasm's type vocabulary stops at `i32`/`i64`/`f32`/`f64`/`v128`/references. A function that "takes a string and returns a list of records" appears in a core module as `(func (param i32 i32) (result i32))` — the meaning lives entirely in an out-of-band convention.

The component model closes that gap in two directions at once:

1. It adds a **second layer** on top of core Wasm with high-level value types — `string`, `list<T>`, `record`, `variant`, `enum`, `flags`, `option<T>`, `result<T, E>`, `tuple`, `own<R>`/`borrow<R>` handles to `resource` types, and (since WASI 0.3.0) `stream<T>`/`future<T>` — plus instance and component types, so an import can be "an instance exporting these functions over these types."
2. It defines the **Canonical ABI**, the mechanical lowering from those types down to core `i32`s and linear-memory layouts, so that two modules compiled by _different_ toolchains with _different_ internal ABIs can be linked through the high-level types without agreeing on anything below them.

**WIT** (Wasm Interface Type) is the human-facing surface of layer 1. It is not a separate artifact format: a WIT package compiles to a component binary whose exports _are_ the type definitions, and a component implementation's own validated type _is_ its world. Extraction is therefore a decoding operation, not a lookup.

The scope note this catalog needs: the component model is not "single-binary packaging" of the kind [§9 of the brief rules out][index]. Its relevance here is that the artifact is _interrogable at the level of meaning_, not just at the level of names — the fourth column of the [comparison table][comparison].

### Design philosophy

From [`design/high-level/Choices.md`][choices], the two choices that make the format queryable at all:

> _"The component model introduces no global singletons, namespaces, registries, locator services or frameworks through which components are configured or linked. Instead, all related use cases are addressed through explicit parametrization of components via imports (of data, functions, and types) with every client of a component having the option to independently instantiate the component with its own chosen import values."_
>
> _"The component model assumes that Just-In-Time compilation is not available at runtime and thus only provides declarative linking features that admit Ahead-of-Time compilation, optimization and analysis. While component instances can be created at runtime, the components being instantiated as well as their dependencies and clients are known before execution begins."_

Both sentences are load-bearing for this catalog. "No registries or locator services" means an import cannot resolve to something the file does not describe — there is no `LD_LIBRARY_PATH`, no `ldconfig` cache, no `dlopen`. "Only declarative linking features that admit … analysis" means the instantiation graph is _data in the file_, not a program the loader runs. Where [`ld.so`][dynlink] executes a search-and-bind algorithm whose result depends on the filesystem and the environment, a component's instantiation graph is a fixed set of `instance`/`alias`/`canon` definitions that a validator walks before anything executes.

The corresponding statement for WIT, from [`design/mvp/WIT.md` § Package Format][wit-md]:

> _"Thus, WIT does not need its own separate package format; WIT can be packaged as a component binary."_

That is the autological move: the interface description language's distribution format is the same binary format as the thing it describes. Compare [SELF][self], where the executable's schema is the executable's own SQLite schema, and [redbean][ape], where the archive index is the executable's own ZIP central directory.

---

## How it works

### The core binary format: a flat sequence of tagged, length-prefixed sections

A core module is an 8-byte preamble followed by sections, each `id: u8`, `size: u32` (LEB128), payload. From [`crates/wasmparser/src/parser.rs`][wt-parser]:

```rust
// wasm-tools crates/wasmparser/src/parser.rs
const CUSTOM_SECTION: u8 = 0;   const ELEMENT_SECTION: u8 = 9;
const TYPE_SECTION: u8 = 1;     const CODE_SECTION: u8 = 10;
const IMPORT_SECTION: u8 = 2;   const DATA_SECTION: u8 = 11;
const FUNCTION_SECTION: u8 = 3; const DATA_COUNT_SECTION: u8 = 12;
const TABLE_SECTION: u8 = 4;    const TAG_SECTION: u8 = 13;
const MEMORY_SECTION: u8 = 5;
const GLOBAL_SECTION: u8 = 6;
const EXPORT_SECTION: u8 = 7;
const START_SECTION: u8 = 8;
```

Non-custom sections must appear **at most once and in ascending id order** (the parser tracks this with `update_order(Order::…)`), so a core module is effectively a fixed-shape record. Section `0` is the escape hatch: a `custom` section carries a UTF-8 name and an opaque payload, may appear any number of times anywhere, and has, per the [core spec appendix][core-custom], no semantic effect.

### The component layer: same envelope, different `layer` field

[`design/mvp/Binary.md`][binary-md] specifies the component grammar and, critically, the discriminator:

```ebnf
component ::= <preamble> s*:<section>*
preamble  ::= <magic> <version> <layer>
magic     ::= 0x00 0x61 0x73 0x6D
version   ::= 0x0d 0x00
layer     ::= 0x01 0x00
```

with the note that

> _"The `layer` field is meant to distinguish modules from components early in the binary format. (Core WebAssembly modules already implicitly have a `layer` field of `0x0` if the existing 4-byte `core:version` field is reinterpreted as two 2-byte fields.)"_

Observed on real files produced during this survey:

```text
core module    : 00 61 73 6d 01 00 00 00      # \0asm, version=1, layer=0
component      : 00 61 73 6d 0d 00 01 00      # \0asm, version=13, layer=1
```

`wasmparser` reads exactly those two `u16`s and dispatches on the pair, rejecting everything else (`"unknown binary version"`). Component section ids are a _different_ namespace over the same envelope: `1` = core module, `2` = core instance, `3` = core type, `4` = nested component, `5` = instance, `6` = alias, `7` = type, `8` = canon, `9` = start, `10` = import, `11` = export, `12` = value, and `0` = custom, shared with core.

Sections `1` and `4` embed **complete, self-delimiting binaries** — a core module or a nested component, byte-for-byte, at a known offset. [`design/mvp/Linking.md`][linking-md] states this outright: a parent component can _"literally storing the child module or component binaries in a contiguous byte range inside the parent."_

### WIT: worlds, interfaces, packages

WIT's three nouns map one-to-one onto component-model types ([`WIT.md`][wit-md]):

| WIT construct | Component-model type | Meaning                                                             |
| ------------- | -------------------- | ------------------------------------------------------------------- |
| `interface`   | `instancetype`       | A named bundle of functions and types                               |
| `world`       | `componenttype`      | A _complete_ description of both imports and exports of a component |
| `package`     | (naming scheme)      | `namespace:name@semver`, e.g. `wasi:clocks@1.2.0`                   |

A `world` is a two-sided contract: it says what the host must supply _and_ what the guest must provide. That symmetry is why the component model can express "this artifact is substitutable for that one" as a single type-check — see [Reflexivity](#reflexivity-and-query-surface).

The example used throughout the rest of this page:

```wit
package sparkles:demo@1.0.0;

interface store {
    /// A key-value bucket.
    resource bucket {
        constructor(name: string);
        get: func(key: string) -> option<string>;
        put: func(key: string, value: string) -> result<_, string>;
    }
}

world kv {
    import store;
    export run: func(args: list<string>) -> result<_, string>;
}
```

Encoded as a WIT package, this is a **597-byte** component whose two `component types` sections carry the entire type graph and whose exports name the two top-level definitions:

```text
$ wasm-tools component wit demo.wit --wasm -o demo-wit.wasm && wasm-tools objdump demo-wit.wasm
  component types                        |        0xb -       0xc0 |       181 bytes | 1 count
  component exports                      |       0xc2 -       0xcd |        11 bytes | 1 count
  component types                        |       0xd0 -      0x1be |       238 bytes | 1 count
  component exports                      |      0x1c0 -      0x1c8 |         8 bytes | 1 count
  custom "package-docs"                  |      0x1d7 -      0x224 |        77 bytes | 1 count
  custom "producers"                     |      0x230 -      0x255 |        37 bytes | 1 count
```

Feeding that binary back to the same tool reproduces the source WIT verbatim, doc comment included.

### The Canonical ABI: how `string` becomes `i32 i32`

[`CanonicalABI.md`][cabi] specifies, _"for each component function signature, a corresponding core function signature and the process for reading component-level values into and out of linear memory"_, presented as executable Python in [`design/mvp/canonical-abi/definitions.py`][cabi-py]. Four `canonopt` settings parameterize it ([`CanonicalOptions`][cabi]): `string_encoding` (default `utf8`), `memory`, `realloc`, and `post_return`, plus `async_`/`callback` for the concurrency additions.

`flatten_functype` decides register-passing versus memory-passing:

```python
# component-model design/mvp/CanonicalABI.md
MAX_FLAT_PARAMS = 16
MAX_FLAT_ASYNC_PARAMS = 4
MAX_FLAT_RESULTS = 1
```

with the honest footnote that _"The number of flattened results is currently limited to 1 due to various parts of the toolchain (notably the C ABI) not yet being able to express multi-value returns."_ Above the limits, a single pointer into linear memory is passed instead, and the caller must supply `realloc`.

The two directions are `canon lift` (core function → component function, i.e. an export) and `canon lower` (component function → core function, i.e. an import). They are the "membrane" the Explainer describes: component-level imports and exports admit only component sorts plus `module`, which

> _"ensures that all cross-component calls transit through a lift/lower trampoline, which allows the Component Model to create a 'membrane' around all the core module instances contained by a component instance."_

The consequence for this catalog is that **no pointer ever crosses a component boundary**. There is no shared address space, therefore no relocation, therefore no symbol binding, therefore nothing for the [loader-as-query-planner][open-q] framing to plan. Values are copied and re-lifted at every hop.

### Building an implementation and reading its interface back

```text
$ wasm-tools component embed demo.wit --world kv --dummy -o core.wasm   # 717 B core module
$ wasm-tools component new core.wasm -o kv.component.wasm               # 1701 B component
$ wasm-tools objdump kv.component.wasm | head -4
  component types                        |        0xb -       0x9f |       148 bytes | 1 count
  component imports                      |       0xa1 -       0xbf |        30 bytes | 1 count
  module                                 |       0xc2 -      0x25f |       413 bytes | 1 count
    ------ start module 0 -------------
```

The 1701-byte component has **24 top-level sections in all**: four `module` sections holding complete core binaries — the user module (413 B), a `wit-component:shim` (380 B), a `wit-component:fixups` (156 B) and a 24 B start module — two `component types`, one `component imports`, one `component exports`, one `producers` custom section, and fifteen sections of pure wiring (6 `component alias`, 5 `canonical functions`, 4 `core instances`). Then:

```text
$ wasm-tools component wit kv.component.wasm
package root:component;

world root {
  import sparkles:demo/store@1.0.0;

  export run: func(args: list<string>) -> result<_, string>;
}
package sparkles:demo@1.0.0 {
  interface store {
    resource bucket {
      constructor(name: string);
      get: func(key: string) -> option<string>;
      put: func(key: string, value: string) -> result<_, string>;
    }
  }
}
```

Two losses are visible and both are honest: the world's own name and package (`kv`, `sparkles:demo`) became `root` / `root:component`, and the `/// A key-value bucket.` doc comment is gone. The first is documented in [`crates/wit-parser/src/decoding.rs`][wt-decoding]:

```rust
// wasm-tools crates/wit-parser/src/decoding.rs — decode_component
// Note that this name is arbitrarily chosen. We may one day perhaps
// want to encode this in the component binary format itself, but for
// now it shouldn't be an issue to have a defaulted name here.
let world_name = "root";
```

The second is documented in [`crates/wit-parser/src/metadata.rs`][wt-metadata]: _"the component model binary format does not have any means of storing documentation and/or item stability inline with items themselves,"_ so docs ride in a `package-docs` custom section that the WIT-package encoding writes and the implementation encoding does not.

Everything _typed_, however, survives exactly: the `bucket` resource, its constructor, its two methods, the `own`/`borrow` distinction, the `option<string>` and `result<_, string>` shapes, and the fully-qualified versioned interface name `sparkles:demo/store@1.0.0`.

---

## Format identity and multiplicity

**One byte stream, one parse.** The component model scores **1** on multiplicity, and the reason is worth stating precisely, because it inverts the [redbean/APE][ape] strategy.

- **No prefix tolerance whatsoever.** The magic `\0asm` must be at offset 0. Nothing can precede it: not a shebang, not an MBR boot sector, not a DOS stub. Every polyglot in [cluster A][polyglot] that works by putting one format's header at byte 0 and another's index in the tail is structurally impossible here.
- **No raw suffix tolerance.** Unlike ZIP — whose [footer-anchored][footer] `EOCD` scan is exactly what makes suffix parasitism work — a Wasm parser must consume sections until EOF lands precisely at a section boundary. Appending 12 bytes of junk gives:

  ```text
  $ printf 'PK\x05\x06junkjunk' >> t1.wasm && wasm-tools validate t1.wasm
  error: unexpected end-of-file (at offset 0x6a7)
  ```

  Concatenating two valid components gives an error the parser anticipates by name — `wasmparser` peeks for the magic number specifically so it can produce a better message than "section name longer than section":

  ```text
  $ cat kv.component.wasm kv.component.wasm > t2.wasm && wasm-tools validate t2.wasm
  error: expected section, got wasm magic number (at offset 0x6a5)
  ```

- **Controlled suffix tolerance, inside a frame.** What you _can_ append is a well-formed custom section: id `0`, LEB length, name vector, payload. Fourteen hand-written bytes carrying the name `sqlite` and the payload `hello`:

  ```text
  $ printf '\x00\x0c\x06sqlitehello' >> t3.wasm && wasm-tools validate t3.wasm && echo VALID
  VALID
  $ wasm-tools objdump t3.wasm | tail -1
    custom "sqlite"                      |      0x6ae -      0x6b3 |         5 bytes | 1 count
  ```

  1701 → 1715 bytes, still a valid component, and the payload is retrievable by name.

This is the interesting structural result: **Wasm is not prefix- or suffix-tolerant, but it is _extension_-tolerant in a typed way.** Where ZIP's tolerance is "ignore anything you do not understand at either end," Wasm's is "carry anything you like, but declare its length and give it a name." That is a strictly stronger property for the purposes of a queryable artifact — an unknown custom section is enumerable, sized, and named, whereas ZIP prefix garbage is invisible to the format. It is a strictly weaker property for the purposes of a [polyglot][polyglot]: you cannot smuggle a second header past it, which also means the whole class of [parser-differential][differ] attacks that rely on "where does the file really start" does not apply. The differential surface that _does_ remain is between validators that disagree about proposal gating — see [Weaknesses](#weaknesses).

**Multiplicity by containment, not superposition.** The one place a `.wasm` file genuinely holds several artifacts is nesting: a component's sections `1` and `4` contain whole binaries, each with its own `\0asm` preamble, at known offsets. The 1701-byte component above contains five valid Wasm binaries (itself plus four modules), and `wasm-tools metadata show` prints their byte ranges as a tree. This is _containment_, not [superposition][polyglot]: the containment is declared by the container, not hidden from it.

**One extension, two grammars.** The last multiplicity wrinkle is the `layer` field. A `.wasm` file is either a module or a component, and today's browsers understand only the first. Node 24.19.0 (V8), asked to compile the component on 2026-08-26:

```text
> WebAssembly.validate(core)      → true
> WebAssembly.validate(component) → false
> new WebAssembly.Module(component)
CompileError: WebAssembly.Module(): expected version 01 00 00 00, found 0d 00 01 00 @+4
```

The discriminator works; it currently fails closed. See [Mutability, dispatch, and trust](#mutability-dispatch-and-trust).

---

## Index anchoring and random access

**Stream-scanned — and this is the format's sharpest weakness relative to ELF.**

There is no index. There is no section header table, no symbol hash table, no offset directory, nothing analogous to ELF's `e_shoff`/`e_phoff` header pointers or `.gnu.hash`'s bucket array. [`Binary.md`][binary-md] is explicit about what replaces them:

> _"As with Core WebAssembly, the Component Model appends each definition to an index space, allowing earlier definitions to be referred to by later definitions in the text and binary format via unsigned integer index."_

and, on validation:

> _"The indices in `sortidx` are validated according to their `sort`'s index spaces, which are built incrementally as each definition is validated."_

There are 13 such index spaces (5 component-level, 6 core, 2 anticipated). Every reference in the file is an ordinal into one of them. To learn what `(type 7)` is, you must have counted the first seven type definitions — which means decoding every preceding section, which means decoding the whole prefix. Nothing is addressable by offset and nothing is addressable by name.

The practical consequence in the reference tooling is stark. `ComponentInfo::from_reader` in [`decoding.rs`][wt-decoding] constructs `Validator::new_with_features(WasmFeatures::all())` and pushes **every** payload through it — including the code sections of every embedded core module — before it can call `component_item_for_import` / `component_item_for_export` to obtain the types. Extracting the interface of a component therefore costs a **full validation of the entire binary**, machine code included. Extracting the exported symbol names of a shared object costs one `pread` of the section header table plus one of `.dynsym`.

Where the interface bytes actually sit differs by artifact kind, and neither placement is an index:

| Artifact                 | Interface material lives at                                                        |
| ------------------------ | ---------------------------------------------------------------------------------- |
| WIT package component    | Front — `component types` + `component exports` in the first 0x1c8 of 597 bytes    |
| Implementation component | **Split** — imports at 0xa1–0xbf, exports at 0x66b–0x674 of 0x6a5, code in between |
| Core module              | Front — `type` (1) then `import` (2), before `code` (10)                           |

So an implementation component is neither header- nor footer-anchored: its import surface is a prefix and its export surface is a suffix, with several hundred bytes of embedded machine code between them, and the export section's `sortidx` ordinals are meaningless without having walked that machine code. A ranged HTTP fetch of the head and the tail — the trick that makes [remote Parquet and remote SQLite][range] work — recovers the _names_ but not the _types_.

> [!NOTE]
> This is the one dimension on which the outline's claim genuinely fails. The component model is arguably the most _declaratively described_ binary interface shipping; it is emphatically **not** the most _randomly accessible_ one. ELF's on-disk layout was designed so `ld.so` could `mmap` and index; Wasm's was designed so a streaming compiler could start emitting machine code from the first byte of the code section. Those are different objectives and the component model inherited the streaming one. Contrast with [`sqlelf`][sqlelf], where the whole point is that the ELF index is already random-access enough to be exposed as virtual tables.

The two things that _are_ cheap:

1. **Kind discrimination in 8 bytes.** Module vs component vs not-Wasm-at-all is a single 8-byte read at offset 0 — cheaper than ELF's `e_ident` + `e_type` + section table hop, and cheaper than ZIP's backwards `EOCD` scan.
2. **Skipping.** Every section is length-prefixed, so a consumer that wants only custom sections can hop section-to-section without decoding any of them (`Parser::skip_section`). `wasm-tools strip -a` does exactly this; on the sample component it dropped 1715 → 1265 bytes without touching a single type.

---

## Reflexivity and query surface

**Score 3 — defining, for the external query surface; absent for runtime self-inspection.** Both halves need stating.

### What you can ask a component that you cannot ask a shared object

The central experiment. `libz.so.1.3.2`, read with `readelf`:

```text
$ readelf -d libz.so.1.3.2 | head -4
 0x0000000000000001 (NEEDED)   Shared library: [libc.so.6]
 0x000000000000000e (SONAME)   Library soname: [libz.so.1]
 0x000000000000001d (RUNPATH)  Library runpath: [/nix/store/jms7…-glibc-2.42-51/lib]
$ readelf --dyn-syms -W libz.so.1.3.2 | grep -w deflate
    28: 0000000000007410  4842 FUNC  GLOBAL DEFAULT   13 deflate
```

That record says: a global function symbol named `deflate` begins at virtual address `0x7410`, occupies 4842 bytes, and lives in section 13. It does not say that `deflate` is `int deflate(z_streamp strm, int flush)`. It cannot: C has no name mangling, so the type is simply not present anywhere in the `.so` unless DWARF happens to have survived stripping ([debug info][debug]). And `NEEDED [libc.so.6]` names a _file_, not an interface.

The same three questions against `kv.component.wasm`:

| Question                                         | Component                                                         | `.so`                                                         |
| ------------------------------------------------ | ----------------------------------------------------------------- | ------------------------------------------------------------- |
| What is the _type_ of the export `run`?          | `func(args: list<string>) -> result<_, string>` — from the binary | `FUNC`, size _N_, address _A_. Signature absent without DWARF |
| What does this artifact depend on, semantically? | `sparkles:demo/store@1.0.0`, an instance with a `bucket` resource | `libc.so.6` — a filename; symbol versions like `GLIBC_2.3.4`  |
| Is the dependency list _exhaustive_?             | Yes — capability-safe; no `dlopen`, no ambient authority          | No — `dlopen`, raw `syscall`, `LD_PRELOAD` all bypass it      |
| Is B a compatible replacement for A?             | A type-check (`semver-check`, below)                              | Needs `libabigail`/`abi-compliance-checker` **over DWARF**    |
| Does this artifact satisfy interface _W_?        | A type-check (`targets`, below)                                   | No mechanism                                                  |

The exhaustiveness row is the one with teeth for the [threat model][threat]. A component's import list is its _entire_ authority: [`Choices.md`][choices] item 2 forbids registries and locator services, and item 1 forbids sharing memory across the membrane. Nothing a component can do at runtime adds to that list. `DT_NEEDED` makes no such promise; it is a hint about what `ld.so` should preload, and every real program routes around it.

### And in the other direction

The questions a `.so` answers and a component cannot, which is a longer list than the claim's boosters usually admit:

- **Where does anything live?** A component has no addresses. No `st_value`, no section VMAs, no `PT_LOAD`, no alignment, no `PT_GNU_RELRO`. Nothing to `mmap`, and nothing for a tool like [`sqlelf`][sqlelf] to select an address range from.
- **How big is this function?** `st_size` exists in ELF; the component model has no per-export size. You can compute a core function body's byte length from the code section, but the mapping from a component export to a core function goes through `canon lift`, adapter modules, and the `wit-component:shim`/`fixups` trampolines — three of the four modules in the sample component are pure plumbing.
- **What relocations remain?** Wasm object files have `reloc.*` sections _before_ linking; a finished component has none, so questions about lazy binding, PLT/GOT layout, or relocation counts have no analogue. (Which also makes the ["symbol binding as query planning"][open-q] open question inapplicable here — there is nothing left to plan.)
- **What is the machine code?** Nothing. A component is portable bytecode; the native artifact is produced later by the engine.

### The query surface itself

Three concrete mechanisms, in increasing order of interest.

**1. Extraction — `wasm-tools component wit`.** Shown above. Note that it works on a **fully stripped** component: after `wasm-tools strip -a` removed every custom section (`producers`, `name`, `component-type`, …), the extracted WIT was byte-identical. The interface is not metadata; it is in the structural sections. This is a genuinely different property from ELF, where `strip` removes `.symtab` (though `.dynsym` survives, being needed at runtime) and where the _typed_ answer only ever lived in a custom-section analogue — `.debug_info` — in the first place.

**2. The typed graph as literal relational tables.** `--json` emits precisely four arrays with integer foreign keys:

```json
{
  "worlds":     [ { "name": "root", "imports": {"interface-0": {"interface": {"id": 0}}},
                    "exports": {"run": {"function": {"result": 6, "params": [{"type": 5}]}}},
                    "package": 1 } ],
  "interfaces": [ { "name": "store", "types": {"bucket": 0}, "functions": { … } } ],
  "types":      [ { "name": "bucket", "kind": "resource", "owner": {"interface": 0} },
                  { "name": null, "kind": {"handle": {"own": 0}} },
                  { "name": null, "kind": {"option": "string"} },
                  { "name": null, "kind": {"result": {"ok": null, "err": "string"}} } ],
  "packages":   [ { "name": "sparkles:demo@1.0.0", "interfaces": {"store": 0} },
                  { "name": "root:component",      "worlds": {"root": 0} } ]
}
```

Four tables; `owner`, `package`, `type`, `id` are foreign keys; anonymous structural types are rows without names. This bears directly on the catalog's [thesis 1][index] ("every binary format eventually reimplements a database, badly"). The component model reimplements one too — but _deliberately, normalized, and shipped_, rather than accreted as `.gnu.hash` (a hand-rolled bloom filter) plus `.strtab` (string interning) plus `st_name` (a hand-maintained foreign key). Whether it is "badly" done is a fair question: the decoded table above contains two structurally identical `result<_, string>` rows (indices 4 and 6), so the decoded form is not canonically deduplicated even though the encoded form is.

**3. Queries answered by the type system itself.** The two most interesting `wasm-tools` subcommands do not implement a query engine at all — they _synthesize a component and ask the validator_.

[`targets.rs`][wt-targets] — "does this binary satisfy world _W_?" — embeds the component under test, encodes _W_ as a component type, imports it, and instantiates one with the other:

```text
$ wasm-tools component targets -w kv demo.wit kv.component.wasm      # exit 0

$ wasm-tools component targets -w v3 sv.wit kv.component.wasm
error: failed to validate encoded bytes
Caused by:
    0: type mismatch for import `v3`
       type mismatch for import `sparkles:demo/store@1.0.0`
       missing expected export `[method]bucket.put` (at offset 0x762)
```

[`semver_check.rs`][wt-semver] — "is _new_ a semver-compatible evolution of _prev_?" — does the same with two worlds, having first stripped all version information _"to ensure that the strings line up for wasmparser's validation which does exact string matching."_ Its doc comment states the predicate:

> _"For example `new` is allowed to have more imports and fewer exports, but types and such must have the exact same structure otherwise (e.g. function params, record fields, etc)."_

Which produces a result worth pausing on. Adding an export is a **breaking change**:

```text
== v1 -> v2 (added `export version: func() -> string;`) ==
error: new world is not semver-compatible with the previous world
Caused by: 0: type mismatch for import `v2`
              missing export named `version` (at offset 0x641)

== v1 -> v3 (changed `run`'s result from result<_, string> to string) ==
error: type mismatch for export `run` … expected string, found result (at offset 0x62b)
```

That asymmetry is not a bug; it falls out of a world being a _bidirectional_ contract. Relaxing a world means demanding less of the implementer (fewer exports) and offering more to it (more imports). It is exactly the variance rule a type-theorist would write down, and it is being enforced on a shipped binary artifact by a general-purpose validator. Nothing in the ELF world is within reach of this.

### The debug-info question: the `name` section and DWARF-in-Wasm

Everything above concerns the _interface_. The complementary question — what can you ask about the artifact's _insides_ — falls back on exactly the same arrangement ELF uses, and gains nothing from the component model.

The [core spec appendix][core-custom] standardizes one custom section, `name`, which maps indices back to identifiers. `wasmparser` decodes twelve subsection kinds ([`readers/core/names.rs`][wt-namesec]): `0` module, `1` function, `2` local, `3` label, `4` type, `5` table, `6` memory, `7` global, `8` element, `9` data, `10` field, `11` tag. That is a symbol table in the [`.symtab`][elf5] sense — index-to-name only, no types, no sizes, no addresses — and it is optional, strippable, and absent from release builds by default.

Real debug information is DWARF, embedded exactly as it is in ELF. From [tool-conventions `Dwarf.md`][dwarf-wasm]:

> _"The DWARF sections are embedded in Wasm binary files as custom sections. Each custom section's name matches the DWARF section name as defined in the DWARF standard, e.g. `.debug_info` or `.debug_line`."_
>
> _"Embedding each DWARF section in its own custom section within the Wasm binary matches how DWARF is embedded into other binary formats."_

The document's own `wasm-objdump --headers` example shows a ~1.7 MiB module whose `code` section is 0xd0b1 (≈52 KiB) while `.debug_info` alone is 0x6915f (≈420 KiB) — DWARF outweighing the code by roughly 8×, the same ratio every ELF toolchain fights. The same repo defines a [`build_id` custom section][buildid] to pair a stripped artifact with archived debug info, with the same semantics as ELF's build-id note and the same caveat that it _"has no semantic effects and can be stripped at any time."_ [Split-DWARF and `debuginfod`][debug] apply unchanged.

Three consequences worth stating plainly:

1. **The component model does not improve the debug-info story at all.** It improves the _interface_ story. Types of exported functions are structural; types of internal variables are DWARF, out-of-band, optional, huge.
2. **But the split is cleaner than ELF's.** In an ELF `.so`, the interface answer and the debug answer are _both_ in optional-ish metadata (`.dynsym` names, `.debug_info` types) and neither is complete. In a component, the interface answer is structural and survives `strip -a`; only the debug answer is metadata. The line between "what this artifact promises" and "how this artifact was built" is drawn in the format rather than by convention.
3. **The custom-section frame is doing an enormous amount of work.** `.debug_*`, `name`, `producers`, `build_id`, `package-docs`, `component-type*`, `dylink.0`, `linking`, `reloc.*`, `target_features` — every convention that could not be typed ended up in id-0 sections. That is [thesis 2][index] ("self-description is what makes a format survivable") cutting both ways in one file: the typed half is self-describing and stable; the untyped half accretes conventions in tool-conventions repositories, exactly as ELF and tar did.

### Runtime self-inspection: absent

The reflexivity axis also asks whether the artifact can interrogate _itself while running_. Here the answer is no, and the reason is structural rather than accidental. The component model provides no `canon` built-in that returns a component's own type, no reflection over index spaces, no equivalent of `dladdr` or `/proc/self/exe`. The [`canon` built-in list][cabi] covers resource lifetime (`resource.new`/`drop`/`rep`), concurrency (`waitable-set.*`, `subtask.*`, `stream.*`, `future.*`), backpressure and context — nothing introspective. A component that wants to know its own WIT must be _given_ it, e.g. as an embedded custom section it imports a host filesystem to read, which is precisely the out-of-band arrangement the format otherwise avoids.

The score stays at 3 because the external query surface is not merely _available_ but _constitutive_: the format's imports and exports are the type graph, so "query the artifact" and "decode the artifact" are the same operation. That is a stronger claim than [sqlelf][sqlelf] can make about ELF, where the query surface is a layer someone built on top. But the honest reading is 3-for-external-queries and 0-for-self-interrogation, and a reader comparing this row to [SELF][self] — which really can `SELECT` from itself mid-execution — should read it that way.

---

## Closure, dedup, and size model

**Score 2 — designed-in, as an explicit binary knob, but with no dedup machinery.**

[`Linking.md`][linking-md] frames closure as one of two orthogonal axes:

> _"A parent component can **inline** its children, literally storing the child module or component binaries in a contiguous byte range inside the parent (via the `core:module` and `component` sections in the binary format). A parent component can **import** its children, using the import to refer to external modules or components."_

That is static-versus-dynamic linking, made a per-child choice inside one container, with the same type discipline either way. And it is reversible in both directions by tooling:

| Direction       | Command                         | Effect                                                                                                                                                                                                           |
| --------------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| import → inline | `wasm-tools component link`     | Fuses core modules into one component                                                                                                                                                                            |
| inline → import | `wasm-tools component unbundle` | _"remove core wasm modules from a component and place them in the directory … The output of this command is a new component which imports the modules that are extracted"_ — with a `--threshold` on module size |

`unbundle` is worth noticing: it converts a closed artifact into an open one _plus a store of extracted modules_, which is the deduplication story a [content-addressed chunking][cas] system would want, expressed at the format level. What the component model does **not** provide is the other half — there is no content hash on an inlined child, no canonical serialization, no notion of "these two components share a module." Two components that inline the same libc pay for it twice, and nothing in the file records that they are the same libc. Contrast [Nix store closures][nix], where the identity of a dependency _is_ its hash, and dedup is free.

There is a fossil of that idea in the format. `wasmparser`'s [`ComponentName`][wt-names] still parses import names of the shape:

```text
locked-dep=<foo:bar/baz>,integrity=<sha256-…>
unlocked-dep=<wasi:io/error>
url=<https://…>,integrity=<sha256-…>
integrity=<sha256-…>
```

An import name that _is_ a content hash, or a URL plus a subresource-integrity digest, is exactly the closure primitive the model is missing. But these forms were removed from the Explainer's `externname` grammar on **2026-07-08** ([commit `609567d7`][cm-external-id]), replaced by the `implements` / `external-id` attributes; `wasm-tools` 1.239.0 still accepts them. See [Weaknesses](#weaknesses).

### Concrete sizes

From the artifacts built for this page (2026-08-26, `wasm-tools` 1.239.0):

| Artifact                             | Bytes | Content                                                                   |
| ------------------------------------ | ----- | ------------------------------------------------------------------------- |
| `demo.wit` (source)                  | 379   | Human-readable WIT                                                        |
| `demo-wit.wasm` (WIT package)        | 597   | The complete type graph, docs, producers — no code at all                 |
| `core.wasm` (stub core module)       | 717   | 4 imports, 4 no-op functions, a memory, a `component-type` custom section |
| `kv.component.wasm`                  | 1701  | The above plus 3 generated adapter modules and 24 wiring sections         |
| `kv.component.wasm` after `strip -a` | 1265  | Same interface, no custom sections                                        |

The interesting ratio is the last two rows against the first: the _entire_ declarative interface of this component — resource, handles, two option/result shapes, versioned package name — costs 597 bytes standalone, and the fully typed implementation costs 1265 bytes stripped. The component-model tax over the bare core module is roughly 550 bytes for this trivial world, most of it the three adapter modules rather than the types. On a real artifact this is noise; on a `wasi:cli` command component it is a fixed cost of a few kilobytes.

> [!NOTE]
> This is a _self-containment_ number, not a closure number. All four inlined modules here were generated by `wit-component`; a real component that inlines libc or a language runtime carries megabytes. The [size-amortization curve][measure] the catalog wants — bytes as a function of object count and shared-library fan-in — has the same shape here as for static linking, because inlining _is_ static linking with a type system on top.

---

## Mutability, dispatch, and trust

### Mutability: 0, and the section is short because the absence is total

A component is not its own state store. There is no writable region in the format, no self-modification path, no transaction. Data segments initialize linear memory at instantiation and the _file_ is never written back. `resource` handles are per-instance table entries that vanish with the instance; [`Choices.md`][choices] item 3 makes explicit that resources have _"lifetimes and require explicit acyclic ownership through handles."_

This is the polar opposite of [SELF/self-httpd][self], where the running program `INSERT`s into the file it is executing from, and of [redbean's][ape] `StoreAsset` under `-*`. The design goal here is the opposite goal: the format wants to be _analyzable ahead of time_, and a mutable artifact is by construction not.

The absence has one interesting consequence for [thesis 4][index] ("`mmap` is the load-bearing constraint"). The component model does not have an `mmap` problem because it does not have an `mmap` story at all — the format specifies no addresses, so demand paging and cross-process text sharing are entirely an engine concern, decided below the format by whatever the runtime does with its compiled artifact. Where SELF must fight to preserve page sharing, a component never had it to lose; it moved the whole question one layer down. That is thesis 5 ("portability has migrated from the format to the access layer") in a different key: not a swappable VFS, but a swappable code generator.

### Dispatch: the loader, on eight bytes, and never the kernel

The `layer` field is the entire dispatch mechanism, and it is checked by the _consumer_, not the operating system. There is no `binfmt_misc` registration for `\0asm`, no `PT_INTERP`, no shebang. The chain is:

1. Some host hands a byte buffer to an engine.
2. The engine reads `magic`/`version`/`layer` and decides module vs component vs reject.
3. Validation walks every section; instantiation walks the declarative `instance`/`alias`/`canon` graph.

Step 1 is where this catalog's cluster K lands, because "some host hands a byte buffer" is an unusually weak precondition compared to `execve`. The [JS API][js-api] takes a `BufferSource`. That buffer's provenance is unconstrained: a `fetch` response, an `ArrayBuffer` assembled in a Worker, or — the case that closes the cluster — **a BLOB read out of a SQLite database through a [VFS][vfs]**.

Put concretely: a Wasm module stored in a `segments`-style table, read by `sqlite3` compiled to Wasm running over OPFS `FileSystemSyncAccessHandle`s, and handed to `WebAssembly.instantiate`, is an autological artifact with **no kernel involvement whatsoever**. The module loader is playing exactly the role [`binfmt_misc`][binfmt] plays for [SELF][self]: it inspects a magic number at a fixed offset and decides what the bytes are. The differences are all in the loader's favour for this purpose —

|              | `binfmt_misc`                                                                                          | `WebAssembly.instantiate`                                              |
| ------------ | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| Registration | Root-only write to `/proc/sys/fs/binfmt_misc/register`; a persistence surface ([threat model][threat]) | None — it is a function call                                           |
| Input        | A path the kernel can `open()`                                                                         | Any `BufferSource`, from any [VFS][vfs]                                |
| Magic check  | Configurable magic + mask + offset                                                                     | Fixed: `\0asm` + `version` + `layer` at offset 0                       |
| Sandbox      | Whatever the delivered interpreter does                                                                | Structural: no ambient authority, imports are the whole capability set |

And the honest caveat, dated: **no browser natively loads a component today.** The V8 rejection quoted above is the current state. [`Goals.md`][goals] anticipates exactly this gap and prescribes the interim answer:

> _"ensure components can be natively supported in browsers by extending the existing WebAssembly integration points: the JS API, Web API and ESM-integration. Before native support is implemented, ensure components can be polyfilled in browsers via Ahead-of-Time compilation to currently-supported browser functionality."_

That polyfill is [`jco transpile`][jco], which lowers a component to ES modules plus core modules — and which is itself delivered as components (`wasm-tools-component`, `js-component-bindgen-component` in the [jco repository][jco]), so the toolchain that makes components run in a browser is written in components. So the browser-native autological artifact of [the outline's cluster K question][open-q] is buildable _today_ at the core-module layer and _tomorrow_ at the component layer; between now and then the module loader dispatches on `01 00 00 00`, not on `0d 00 01 00`.

### Trust

Three observations, none of them flattering to a naive "components are safe" reading.

1. **Capability-safety is real and is the strongest security property here.** The import list is the complete authority set. A component that does not import `wasi:filesystem` cannot touch a file — not by `dlopen`, not by a raw syscall, not by an `LD_PRELOAD`-style injection, because none of those mechanisms exist inside the membrane. This is the property [Landlock, pledge, and seccomp-BPF][threat] approximate from outside a process; here it is enforced by the type system before execution starts.
2. **Nothing in the format is signed.** There is no signature section, no canonical serialization, no Merkle structure. The `build_id` custom section from [tool-conventions][buildid] is _"a custom section and thus has no semantic effects and can be stripped at any time"_ — the same caveat as ELF's build-id note ([provenance][prov]), plus the same guidance that any transformation invalidating debug info should drop or recompute it. Signing a component means signing the file, out of band, exactly as for any other opaque blob. The `integrity=<sha256-…>` import names are the closest the format got to in-band integrity, and they are the forms currently in retreat.
3. **The custom-section frame is an unaudited channel.** Everything above — `name`, `.debug_*`, `producers`, `package-docs`, `build_id`, `dylink.0`, `linking`, `reloc.*`, `target_features`, `wit-component-encoding`, plus my `sqlite`/`hello` — rides in id-0 sections that validators must accept and ignore. `wasm-tools strip` deliberately preserves `name`, `component-type`, and `dylink.0` unless `--all` is passed, so the default "strip" leaves a channel open. Unknown custom sections are enumerable and sized, which is better than ZIP prefix slack, but they are still arbitrary attacker-chosen bytes in a file whose validity does not depend on them.

---

## Strengths

- **The interface is in the structural sections, not in metadata.** A fully stripped component still yields exact WIT. There is no debuginfod, no `.debug_info`, no external `.d.ts`; the answer cannot be lost by a `strip`.
- **Types, not names.** `func(args: list<string>) -> result<_, string>` versus `FUNC GLOBAL DEFAULT 13 run`. The gap is the whole argument.
- **Imports are exhaustive and capability-scoped.** No ambient authority, no `dlopen`, no registry, no locator service — by [explicit design choice][choices].
- **Queries are type-checks.** `targets` and `semver-check` are implemented by synthesizing a component and running the validator, so the query semantics _are_ the format semantics — no second model to drift.
- **Round-trip is real and small.** 379 bytes of WIT → 597-byte component → identical WIT, doc comments included.
- **Extension-tolerant in a typed way.** Appending a named, length-prefixed custom section is 14 bytes and keeps the file valid; unknown sections stay enumerable rather than invisible.
- **Closure is a declared, reversible knob.** Inline or import, per child, with `link`/`unbundle` moving between them.
- **One extension, unambiguously discriminated.** Eight bytes decide module vs component vs neither, at offset 0, with no scanning.

## Weaknesses

- **No index, anywhere.** Positional index spaces mean nothing is addressable by offset or name; extracting an interface costs a full validation of the whole binary, machine code included ([`decoding.rs`][wt-decoding]). ELF answers "where is `deflate`" with two `pread`s.
- **Interface material is split across the file.** In an implementation component imports are a prefix and exports a suffix with code between, so the [ranged-read trick][range] recovers names but not types.
- **Names above the type level are lost.** `decode_component` invents `root` / `root:component` because the world's own identity _"is not otherwise encoded in a binary component"_.
- **Docs and stability annotations need a custom section.** [`metadata.rs`][wt-metadata]: the binary format _"does not have any means of storing documentation and/or item stability inline with items themselves."_ `@since`/`@unstable` gates are erased at encode time entirely ([`WIT.md`][wit-md]).
- **The naming grammar is in flux.** `locked-dep=`/`unlocked-dep=`/`url=`/`integrity=` import names left the Explainer on 2026-07-08 ([`609567d7`][cm-external-id]) in favour of `implements`/`external-id`, while `wasm-tools` 1.239.0 still parses them. Two shipped artifacts can disagree about what a valid import name is.
- **A large gated surface.** [`Explainer.md`][explainer] lists ten emoji-gated feature groups (🪙 values/start, 🪺 nested namespaces, 🧵 threads, 🔧 fixed-length lists, 📝 `error-context`, 🔗 canonical interface names, 🐘 memory64, …) that are _"in various stages of implementation, are not enabled by default, may have breaking changes."_ Validators differ on which are on — the real [parser-differential][differ] surface for Wasm is proposal gating, not header ambiguity.
- **`MAX_FLAT_RESULTS = 1`** is a toolchain artifact baked into the ABI, acknowledged as such: _"Hopefully this limitation is temporary."_
- **Shared-everything linking re-derives ELF.** Where the component model's shared-nothing model does not fit, the ecosystem falls back to the `dylink.0` custom section, which reintroduces `needed_dynlibs_entries` (a name list) and `WASM_DYLINK_RUNTIME_PATH`, described in [tool-conventions][dylink] as _"corresponding to `DT_RUNPATH` in an ELF `.dynamic` section."_ Same for `linking`'s `WASM_SYMBOL_TABLE`. Two linking universes coexist, and the untyped one is still where libc lives.
- **No signing, no canonical form, no in-band integrity.** See [trust](#trust).
- **No browser support yet, and it is 2026-08-26.** Components run in browsers only via [`jco`][jco] AOT transpilation.
- **No runtime self-inspection.** No `canon` built-in returns a component's own type.

---

## Key design decisions and trade-offs

| Decision                                                                     | Rationale                                                                                                       | Trade-off                                                                                                              |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Layer the component model _over_ core Wasm using the `layer` preamble field  | Reuses the entire core envelope, validator, and streaming decoder; one file extension, one magic                | Today's engines reject components outright; the core spec still owes a backwards-compatible `version`/`layer` split    |
| Positional index spaces instead of an offset or hash table                   | Streaming compilation: an engine can emit machine code from the first byte of the code section without seeking  | Nothing is randomly accessible; extracting an interface requires validating the entire binary                          |
| Encode WIT _as a component_ rather than defining a package format            | Reuses _"the tricky type bits"_; downstream tools skip the resolution environment entirely ([`WIT.md`][wit-md]) | Docs, stability gates, and the world's own name fall outside the type encoding and need a custom section — or are lost |
| Shared-nothing across the component boundary; copy values through a membrane | Fine-grained sandboxing; different toolchains need not agree below the type level ([`Choices.md`][choices])     | Every cross-component call copies; a shared libc needs the untyped `dylink.0` path instead                             |
| Canonical ABI as executable Python with hard flattening limits               | Precise and testable; small values ride registers instead of memory                                             | `MAX_FLAT_RESULTS = 1` is a C-ABI limitation frozen into a spec; `realloc` is mandatory above the limits               |
| Custom sections as the only extension mechanism                              | Named, length-prefixed, ignorable — extension without ambiguity                                                 | An unaudited attacker-controlled channel that `strip` preserves by default                                             |
| Declarative-only linking (no JIT assumed)                                    | The whole instantiation graph is analyzable AOT; imports are an exhaustive capability list                      | No plugin systems, no runtime module discovery; anything dynamic must be modelled as an import                         |
| No signing, no canonical serialization in the format                         | Keeps the format small; signing is a distribution concern ([application-packaging][pkg])                        | No in-band integrity; the `integrity=` import-name forms that came closest are being withdrawn                         |
| Inline-or-import children as a per-child choice                              | Static and dynamic linking in one container, reversible by `link`/`unbundle`                                    | No content addressing, so no dedup: two components inlining the same libc pay twice and cannot tell                    |

---

## Sources

- [WebAssembly/component-model — design repository][cm-repo] (read at `4acb0deec245ec84972335762738adb303907612`, 2026-08-24)
- [`design/mvp/Binary.md` — the component binary grammar, `layer`, section ids][binary-md]
- [`design/mvp/Explainer.md` — index spaces, import/export names, gated features][explainer]
- [`design/mvp/WIT.md` — the IDL, and the package format ("WIT can be packaged as a component binary")][wit-md]
- [`design/mvp/CanonicalABI.md` — lift/lower, `canonopt`, flattening limits][cabi] · [`canonical-abi/definitions.py`][cabi-py]
- [`design/mvp/Linking.md` — shared-nothing vs shared-everything, inline vs import][linking-md]
- [`design/high-level/Goals.md`][goals] · [`design/high-level/Choices.md`][choices]
- [bytecodealliance/wasm-tools][wt-repo] (read at `faf4672926371c0bafe0f3955dd4dfce567b3a93`, 2026-08-25; binary `1.239.0`)
- [`crates/wasmparser/src/parser.rs` — section ids, preamble dispatch, ordering][wt-parser]
- [`crates/wasmparser/src/validator/names.rs` — `ComponentNameKind`, `locked-dep=`/`integrity=`][wt-names]
- [`crates/wasmparser/src/readers/core/names.rs` — name-section subsections 0–11][wt-namesec]
- [`crates/wit-parser/src/decoding.rs` — full validation, then type extraction; `root` defaulting][wt-decoding]
- [`crates/wit-parser/src/metadata.rs` — the `package-docs` custom section][wt-metadata]
- [`crates/wit-component/src/metadata.rs` — the `component-type*` custom section in core modules][wt-cmeta]
- [`crates/wit-component/src/targets.rs` — "does this satisfy world W" as an instantiation][wt-targets]
- [`crates/wit-component/src/semver_check.rs` — semver as a type-check][wt-semver]
- [`crates/wasm-metadata/src/lib.rs` — OCI-style `authors`/`licenses`/`revision` custom sections][wt-wasmmeta]
- [WebAssembly/tool-conventions][tc-repo] (read at `83e5d715d0c18aee51e2d5ae9434f22d67b6e905`): [`Dwarf.md`][dwarf-wasm], [`DynamicLinking.md`][dylink], [`Linking.md`][tc-linking], [`BuildId.md`][buildid], [`ProducersSection.md`][producers]
- [WebAssembly core specification — binary format, modules and sections][core-binary] · [custom sections and the name section][core-custom]
- [WebAssembly JS API specification][js-api]
- [Component Model Documentation (Bytecode Alliance book)][cm-book] — [why][cm-why], [worlds][cm-worlds], [interfaces][cm-interfaces], [WIT][cm-wit]
- [bytecodealliance/jco — component→ESM transpilation][jco] (read at `f191423e5c2cd58783eeebf6347ed16189b7c1a7`)
- [ELF gABI — the dynamic section (`DT_NEEDED`, `DT_RUNPATH`, `DT_SONAME`)][elf-dynamic] · [`elf(5)`][elf5]
- [DWARF 5 standard][dwarf5]
- Related in this tree: [dynamic linking][dynlink] · [`binfmt_misc`][binfmt] · [sqlelf][sqlelf] · [SELF/selfdb][self] · [SQLite VFS as substrate][vfs] · [footer-indexed formats][footer] · [range-request access][range] · [debug info and indexes][debug] · [embedded provenance][prov] · [threat model][threat] · [Cosmopolitan/APE][ape] · [comparison][comparison]

<!-- References -->

[cm-repo]: https://github.com/WebAssembly/component-model/tree/4acb0deec245ec84972335762738adb303907612
[binary-md]: https://github.com/WebAssembly/component-model/blob/4acb0deec245ec84972335762738adb303907612/design/mvp/Binary.md
[explainer]: https://github.com/WebAssembly/component-model/blob/4acb0deec245ec84972335762738adb303907612/design/mvp/Explainer.md
[wit-md]: https://github.com/WebAssembly/component-model/blob/4acb0deec245ec84972335762738adb303907612/design/mvp/WIT.md
[cabi]: https://github.com/WebAssembly/component-model/blob/4acb0deec245ec84972335762738adb303907612/design/mvp/CanonicalABI.md
[cabi-py]: https://github.com/WebAssembly/component-model/blob/4acb0deec245ec84972335762738adb303907612/design/mvp/canonical-abi/definitions.py
[linking-md]: https://github.com/WebAssembly/component-model/blob/4acb0deec245ec84972335762738adb303907612/design/mvp/Linking.md
[goals]: https://github.com/WebAssembly/component-model/blob/4acb0deec245ec84972335762738adb303907612/design/high-level/Goals.md
[choices]: https://github.com/WebAssembly/component-model/blob/4acb0deec245ec84972335762738adb303907612/design/high-level/Choices.md
[cm-external-id]: https://github.com/WebAssembly/component-model/commit/609567d78a1a90141e05583ecb3dc28e7588327f
[wt-repo]: https://github.com/bytecodealliance/wasm-tools/tree/faf4672926371c0bafe0f3955dd4dfce567b3a93
[wt-parser]: https://github.com/bytecodealliance/wasm-tools/blob/faf4672926371c0bafe0f3955dd4dfce567b3a93/crates/wasmparser/src/parser.rs
[wt-names]: https://github.com/bytecodealliance/wasm-tools/blob/faf4672926371c0bafe0f3955dd4dfce567b3a93/crates/wasmparser/src/validator/names.rs
[wt-namesec]: https://github.com/bytecodealliance/wasm-tools/blob/faf4672926371c0bafe0f3955dd4dfce567b3a93/crates/wasmparser/src/readers/core/names.rs
[wt-decoding]: https://github.com/bytecodealliance/wasm-tools/blob/faf4672926371c0bafe0f3955dd4dfce567b3a93/crates/wit-parser/src/decoding.rs
[wt-metadata]: https://github.com/bytecodealliance/wasm-tools/blob/faf4672926371c0bafe0f3955dd4dfce567b3a93/crates/wit-parser/src/metadata.rs
[wt-cmeta]: https://github.com/bytecodealliance/wasm-tools/blob/faf4672926371c0bafe0f3955dd4dfce567b3a93/crates/wit-component/src/metadata.rs
[wt-targets]: https://github.com/bytecodealliance/wasm-tools/blob/faf4672926371c0bafe0f3955dd4dfce567b3a93/crates/wit-component/src/targets.rs
[wt-semver]: https://github.com/bytecodealliance/wasm-tools/blob/faf4672926371c0bafe0f3955dd4dfce567b3a93/crates/wit-component/src/semver_check.rs
[wt-wasmmeta]: https://github.com/bytecodealliance/wasm-tools/blob/faf4672926371c0bafe0f3955dd4dfce567b3a93/crates/wasm-metadata/src/lib.rs
[tc-repo]: https://github.com/WebAssembly/tool-conventions/tree/83e5d715d0c18aee51e2d5ae9434f22d67b6e905
[dwarf-wasm]: https://github.com/WebAssembly/tool-conventions/blob/83e5d715d0c18aee51e2d5ae9434f22d67b6e905/Dwarf.md
[dylink]: https://github.com/WebAssembly/tool-conventions/blob/83e5d715d0c18aee51e2d5ae9434f22d67b6e905/DynamicLinking.md
[tc-linking]: https://github.com/WebAssembly/tool-conventions/blob/83e5d715d0c18aee51e2d5ae9434f22d67b6e905/Linking.md
[buildid]: https://github.com/WebAssembly/tool-conventions/blob/83e5d715d0c18aee51e2d5ae9434f22d67b6e905/BuildId.md
[producers]: https://github.com/WebAssembly/tool-conventions/blob/83e5d715d0c18aee51e2d5ae9434f22d67b6e905/ProducersSection.md
[jco]: https://github.com/bytecodealliance/jco/blob/f191423e5c2cd58783eeebf6347ed16189b7c1a7/README.md
[core-binary]: https://webassembly.github.io/spec/core/binary/modules.html
[core-custom]: https://webassembly.github.io/spec/core/appendix/custom.html
[js-api]: https://webassembly.github.io/spec/js-api/index.html
[cm-book]: https://component-model.bytecodealliance.org/
[cm-why]: https://component-model.bytecodealliance.org/design/why-component-model.html
[cm-worlds]: https://component-model.bytecodealliance.org/design/worlds.html
[cm-interfaces]: https://component-model.bytecodealliance.org/design/interfaces.html
[cm-wit]: https://component-model.bytecodealliance.org/design/wit.html
[elf-dynamic]: https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.dynamic.html
[elf5]: https://man7.org/linux/man-pages/man5/elf.5.html
[dwarf5]: https://dwarfstd.org/doc/DWARF5.pdf
[index]: ./index.md
[comparison]: ./comparison.md
[measure]: ./measurement.md
[open-q]: ./open-questions.md
[dynlink]: ./dynamic-linking.md
[binfmt]: ./binfmt-misc.md
[sqlelf]: ./sqlelf.md
[self]: ./self-selfdb/index.md
[ape]: ./cosmopolitan-ape/index.md
[vfs]: ./sqlite-vfs-substrate.md
[footer]: ./footer-indexed-formats.md
[range]: ./range-request-access.md
[debug]: ./debug-info-and-indexes.md
[prov]: ./embedded-provenance.md
[threat]: ./threat-model.md
[polyglot]: ./polyglot-craft.md
[differ]: ./parser-differentials.md
[nix]: ./nix-store-closures.md
[cas]: ./content-addressed-chunking.md
[pkg]: ../application-packaging/index.md
