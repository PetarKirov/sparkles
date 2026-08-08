# serde (Rust)

The Rust ecosystem's universal (de)serialization framework: a fixed 29-type abstract data model with derive macros on one side and format implementations on the other, so `N` data structures and `M` formats cost `N + M` implementations instead of `N × M`.

| Field         | Value                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------ |
| Language      | Rust (`no_std` supported via `default-features = false`; `alloc` optional)                             |
| License       | MIT OR Apache-2.0 (dual)                                                                               |
| Repository    | [serde-rs/serde][repo]                                                                                 |
| Documentation | [serde.rs][site] · [docs.rs/serde][docs] · [crates.io][crate]                                          |
| Category      | Derive-macro (de)serialization framework — static, monomorphized codecs (see [the three tiers][tiers]) |
| Key authors   | David Tolnay (`dtolnay`), Erick Tryzelaar, and contributors                                            |
| First release | `1.0.0` — April 2017 (`0.x` line from 2014)                                                            |
| Status        | Actively maintained; the de-facto standard, depended on by most of the Rust ecosystem                  |

> [!NOTE]
> This deep-dive is scoped to **expressiveness** — what a schema declaration can and cannot say — because that is what feeds the [`sparkles:wired` redesign][baseline]. serde's argv/CLI story (`clap`, `serde_args`, `facet-args`) is analysed separately in [argv codecs][argv].

---

## Overview

### What it solves

Before serde, every Rust format crate defined its own conversion traits, and every data structure had to opt into each of them. serde's move is to insert **one fixed abstract type universe** between the two halves. From [the data model documentation][data-model]:

> _"The Serde data model is the API by which data structures and data formats interact. You can think of it as Serde's type system. … In code, the serialization half of the Serde data model is defined by the `Serializer` trait and the deserialization half is defined by the `Deserializer` trait. These are a way of mapping every Rust data structure into one of 29 possible types."_

A type implements `Serialize`/`Deserialize` **once**, expressed purely in terms of the 29 model types. A format implements `Serializer`/`Deserializer` **once**, mapping the 29 types to bytes. Every pairing then works. This is the single best idea in the ecosystem and the one [`sparkles:wired`][baseline] already shares in spirit.

### Design philosophy

Three commitments follow from that architecture, and they explain nearly every wart in this document:

1. **Zero-cost through monomorphization.** `Serializer` and `Deserializer` are generic traits, so `to_string::<Config>` compiles down to straight-line code with no dynamic dispatch and no intermediate `Value` tree. The price is compile time and code size per (type × format) pair.
2. **The derive is a syntactic macro.** `serde_derive` is a proc macro; it sees only the token stream of the item it is attached to. This is the structural fact that this whole page keeps returning to (see [Design philosophy: what the macro can see](#the-one-structural-difference-that-drives-everything)).
3. **Serde deliberately declines adjacent concerns.** No validation layer, no error accumulation, no reflection, no schema. Each was left to the ecosystem, and each spawned a crate: [`validator`][validator]/[`garde`][garde], [`eserde`][eserde], [`facet`][facet], [`schemars`][schemars].

#### The one structural difference that drives everything

When `serde_derive` processes:

```rust
#[derive(Deserialize)]
struct Outer {
    #[serde(flatten)]
    inner: Inner,
}
```

it knows the _identifier_ `Inner` and nothing else. It cannot look up `Inner`'s definition, enumerate its fields, read its attributes, or even learn whether `Inner` is a struct or an enum — Rust macro expansion runs before name resolution, so cross-type knowledge is unavailable at codegen time. Everything serde does across a type boundary is therefore deferred to **runtime**, through the `Deserialize` trait. That is why `flatten` buffers into a dynamic `Content` map, and why `deny_unknown_fields` cannot see through it.

**D's introspection is semantic, not syntactic.** At the point where wired generates code for `Outer`, `__traits(allMembers, Inner)`, `__traits(getAttributes, ...)`, `is(T == struct)`, and `__traits(docComment, ...)` are all available for `Inner` — transitively, for the entire reachable type graph.

This is not an ergonomic edge; it is the reason a majority of serde's famous limitations are simply not limitations for wired, and it should be wired's organizing principle: **compute the complete static schema of the whole type graph first, then generate the codec against that schema**, rather than serde's per-type, composition-at-runtime model.

---

## How it works

### The 29 types

**14 primitives:** `bool`, `i8`, `i16`, `i32`, `i64`, `i128`, `u8`, `u16`, `u32`, `u64`, `u128`, `f32`, `f64`, `char`.

**15 composites:**

| Model type        | Meaning                                                          |
| ----------------- | ---------------------------------------------------------------- |
| `string`          | UTF-8, length known, no null terminator                          |
| `byte array`      | `[u8]`                                                           |
| `option`          | `None` or `Some(v)` — the _only_ nullability the model has       |
| `unit`            | `()`, the anonymous empty value                                  |
| `unit_struct`     | `struct Unit;`                                                   |
| `unit_variant`    | `E::A` in `enum E { A, B }`                                      |
| `newtype_struct`  | `struct Millimeters(u8)`                                         |
| `newtype_variant` | `E::N(u8)`                                                       |
| `seq`             | variable-length sequence; length may be unknown up front         |
| `tuple`           | fixed-length sequence, length known at compile time on both ends |
| `tuple_struct`    | `struct Rgb(u8, u8, u8)`                                         |
| `tuple_variant`   | `E::T(u8, u8)`                                                   |
| `map`             | variable-size key-to-value pairing                               |
| `struct`          | fixed-size, statically-known **string** keys                     |
| `struct_variant`  | `E::S { r: u8, g: u8 }`                                          |

The distinctions are deliberately finer than JSON's. `tuple` versus `seq` exists so a format that knows the length can elide it. `struct` versus `map` exists so a compact binary format can drop the keys entirely while a self-describing one keeps them. `newtype_struct` exists so wrappers can be made invisible (`Millimeters(5)` emitted as `5`) **by the format's choice**, not the type's.

### The `Serializer` / `Deserializer` asymmetry

Serialization is a **push**: the value knows its shape and calls the matching method.

```rust
impl Serialize for Rgb {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut st = s.serialize_struct("Rgb", 3)?;
        st.serialize_field("r", &self.r)?;
        st.serialize_field("g", &self.g)?;
        st.serialize_field("b", &self.b)?;
        st.end()
    }
}
```

Deserialization is a **pull with a callback**: the type supplies a `Visitor` describing what it can accept, and the _format_ decides which visitor method to call based on what it finds.

```rust
impl<'de> Deserialize<'de> for Rgb {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_struct("Rgb", FIELDS, RgbVisitor)   // a *hint*, not a command
    }
}
```

`deserialize_struct` is a **hint**. A self-describing format may ignore it and call `visit_seq` because it found an array. That latitude is what makes `deserialize_any` — and therefore `untagged` and `flatten` — possible on self-describing formats and impossible on the rest.

### Self-describing versus non-self-describing formats

A **self-describing** format (JSON, YAML, MessagePack, CBOR) carries enough information that `deserialize_any` works: you can parse without knowing the target type. A **non-self-describing** format ([`bincode`][bincode], [`postcard`][postcard], `bitcode`) is a bare byte stream whose meaning depends entirely on the schema; both ends must agree on the type in advance.

The capability split propagates through the whole attribute catalogue:

| Feature                                   | Needs self-describing? | Why                                         |
| ----------------------------------------- | ---------------------- | ------------------------------------------- |
| `#[serde(untagged)]`                      | **Yes**                | must buffer and re-try variants             |
| `#[serde(flatten)]`                       | **Yes**                | must collect unclaimed keys into a map      |
| `#[serde(tag = "...")]` internally tagged | **Yes**                | must find a key before knowing the shape    |
| `deserialize_any`                         | **Yes**                | definitionally                              |
| externally tagged enums                   | No                     | the only representation that works no-alloc |
| `#[serde(default)]`                       | No                     | absence is representable                    |

Non-self-describing formats also impose demands the model has no vocabulary for. **Field order is the contract** (no keys on the wire means declaration order _is_ the format, and reordering fields is a silent breaking change); `skip_serializing_if` is outright dangerous there, because conditional presence with no key to signal absence corrupts the stream, and serde does not stop you. There is **no schema-evolution concept at all** — [`serde_describe`][serde-describe] exists to bolt a schema onto `bincode`/`postcard` streams so they behave self-describingly, which is an admission.

[`rkyv`][rkyv] is the instructive non-adopter: it is deliberately **not** built on serde, because `Deserialize` assumes you construct a value, whereas rkyv's premise is that you _do not deserialize at all_ — you validate the buffer and access the archived form in place. That needs a relocatable memory layout (relative pointers) which serde's model cannot describe.

---

## Schema model & bidirectionality

serde's schema is the derive's output, and it is genuinely bidirectional: one `#[derive(Serialize, Deserialize)]` yields both directions from one declaration, and the attribute vocabulary is direction-aware throughout (`rename(serialize = ..., deserialize = ...)`, `skip_serializing` versus `skip_deserializing`, `alias` being deserialize-only). Round-trip minimality has a dedicated lever in `skip_serializing_if`.

The **cost of a _fixed_ model** is real and is serde's most-cited structural complaint, [serde#1556][serde-1556] — titled, verbatim, _"Deserializing richer types than in Serde's data model is extremely painful."_ Formats richer than the model cannot round-trip through it. PDF distinguishes _strings_ from _names_; serde has one `string`. PDF's indirect references are 2-tuples distinct from arrays; serde has one `seq`-shaped answer. TOML datetimes have no home. The documented escape hatch is a hack: formats smuggle extra types through `newtype_struct` with a magic name, and `visit_newtype_struct` does not even receive the name — the reporter in #1556 needed roughly 100 lines of fake deserializers plus hand-rolled `EnumAccess`/`VariantAccess` impls to work around it.

**Zero-copy** is the other half of the schema story. The `'de` lifetime lets a deserialized struct **borrow** from the input buffer:

```rust
#[derive(Deserialize)]
struct Record<'a, 'b> {
    username: &'a str,          // implicitly borrowed — &str and &[u8] always are
    #[serde(borrow)]
    comment: Cow<'b, str>,      // other types need the explicit opt-in
    count: u32,                 // not borrowed
}
```

The real content of the feature is the visitor's three-way data trichotomy, which is language-independent: **transient** (`visit_str`, valid only during the call — an IO stream, or a JSON string whose `\n` escapes had to be unescaped into a scratch buffer), **borrowed** (`visit_borrowed_str`, valid for `'de`, only possible when the bytes appear verbatim in a caller-owned slice), and **owned** (`visit_string`, the deserializer already allocated). `DeserializeOwned` is sugar for "borrows nothing" and is what `from_reader` requires.

**D verdict — [(b)][tags], and the fixed model is the trap to avoid.** The routing idea transfers trivially; the _fixed 29_ does not. wired's near-term formats (JSON, argv) plus likely future ones (TOML, a compact binary) have genuinely disjoint type vocabularies: argv has "flag", "repeat-count", "positional"; TOML has datetimes; a binary format has fixed-width integers. Make wired's model **open** — a core set plus a format-declared extension set discovered by Design-by-Introspection (`hasCapability!(Format, "datetime")`). D can do this because the format marker is a compile-time parameter, so an extension either exists at compile time or the fallback path is compiled instead; serde cannot, because `Serializer` is a runtime trait with a closed method list. Make `isSelfDescribing` a DbI property of the format marker too, so `@WireFlatten`/`@WireUntagged`/`@WireTag` meeting a format that cannot host them is a `static assert` with a sentence of explanation rather than a runtime surprise. On zero-copy the verdict is also [(b)][tags] but it is a genuine design fork: D slices _are_ borrowed views, so `const(char)[] name` filled from an input buffer is zero-copy with no annotation, and `-preview=dip1000` `scope`/`return scope` is the (weaker) safety story — but the escape problem is language-independent and needs the same three-way answer, ideally a `MaybeOwned!char` primitive in `sparkles:base` whose `@nogc` variant is a caller-owned `SmallBuffer`. For argv this is nearly free and worth taking: `argv` strings live for the whole process, so a parsed-args struct of `const(char)[]` slices needs no allocation at all — a place wired can beat `clap`, which allocates `String`s throughout. Finally, **do not port the `Visitor` pattern**: it exists to get monomorphized dispatch without virtual calls, which D templates give for free, and it is the direct cause of the error-quality problems below.

---

## Naming, optionality & defaults

### Naming

| Attribute                                              | Serialize                       | Deserialize             |
| ------------------------------------------------------ | ------------------------------- | ----------------------- |
| `#[serde(rename = "n")]`                               | emit `n`                        | expect `n`              |
| `#[serde(rename(serialize = "a", deserialize = "b"))]` | emit `a`                        | expect `b`              |
| `#[serde(rename_all = "camelCase")]` (container)       | convert all field/variant names | expect converted        |
| `#[serde(rename_all_fields = "...")]` (container)      | convert fields of every variant | ditto                   |
| `#[serde(alias = "n")]` (repeatable)                   | _no effect_                     | additionally accept `n` |

The case vocabulary is `lowercase`, `UPPERCASE`, `PascalCase`, `camelCase`, `snake_case`, `SCREAMING_SNAKE_CASE`, `kebab-case`, `SCREAMING-KEBAB-CASE`.

Two details are worth stealing. **Direction-split renaming** is what lets you migrate a wire name without breaking old readers. **`alias` is deserialize-only and repeatable**, which is the correct asymmetry: you accept many spellings, you emit exactly one.

### Presence, absence, defaults

| Attribute                                | Serialize                       | Deserialize                          |
| ---------------------------------------- | ------------------------------- | ------------------------------------ |
| `#[serde(default)]`                      | none                            | missing becomes `Default::default()` |
| `#[serde(default = "path")]`             | none                            | missing becomes `path()`             |
| `#[serde(skip)]`                         | omit                            | ignore input; use default            |
| `#[serde(skip_serializing)]`             | omit                            | normal                               |
| `#[serde(skip_deserializing)]`           | normal                          | ignore; use default                  |
| `#[serde(skip_serializing_if = "path")]` | omit when the predicate is true | none                                 |

`skip_serializing_if` is the load-bearing one for round-trip minimality — it is how you emit the shortest representation that reads back identically. Note that serde makes you write the predicate by hand (`"Option::is_none"`, `"Vec::is_empty"`): it has no notion of "equal to the default", because comparing against a default would require a `PartialEq` bound serde declines to demand.

**D verdict — [(a)][tags], with one improvement available.** All of these map to UDAs directly, and wired already has `@WireName`/`@WireCase`; add direction-split spelling (`@WireName(serialize: "a", deserialize: "b")` via DIP1030 named arguments) and a repeatable `@WireAlias`. The improvement is `@WireSkipIfDefault` implemented **generically**: wired can test `is(typeof(field == field))` by DbI and fall back to a predicate when the type is not comparable, whereas serde cannot express "add this bound only if it holds". That matters disproportionately for argv, where "emit the shortest command line that reproduces this struct" is exactly _skip if equal to default_, and where naming is the core mechanism (`--first-name` is kebab-case renaming, `-f` is an alias, a legacy `--firstName` is another alias).

---

## Sum types & discrimination

Given `enum Message { Request { id: String }, Response(u32), Ping }`, serde offers a four-way choice ([enum representations][enum-repr]):

**Externally tagged (default)** — `{"Request": {"id": "x"}}`, `{"Response": 32}`, `"Ping"`. The variant is known _before_ parsing content, so no buffering is needed. It is the only representation that works in no-alloc and non-self-describing settings, and it supports every variant shape.

**Internally tagged** — `#[serde(tag = "type")]` gives `{"type": "Request", "id": "x"}`. Flat and readable, common in JavaScript and Java APIs. It **cannot represent tuple variants at all** (a compile error) and cannot represent a newtype variant over a non-map. It requires `alloc` to deserialize, because it must buffer the map to find `type` before it knows the shape. Applied to a struct rather than an enum, `tag` inserts the struct name as a leading field.

**Adjacently tagged** — `#[serde(tag = "t", content = "c")]` gives `{"t": "Request", "c": {"id": "x"}}`. It handles every variant shape _and_ keeps the tag explicit; Haskell-idiomatic. It requires `alloc`, since tag and content may arrive in either order.

**Untagged** — `#[serde(untagged)]` gives `{"id": "x"}`, `32`, `null`. No discriminator: serde buffers the input into a `Content` value and tries each variant **in declaration order**, returning the first success. It requires `alloc`, is slow, and produces the notorious error `data did not match any variant of untagged enum Message` with no indication of _why_ any variant failed — the subject of a well-known write-up, ["Serde untagged enum errors are bad"][untagged-blog].

Variant-level modifiers: `#[serde(other)]` marks a catch-all **unit** variant for unrecognized tags (internally and adjacently tagged only), and `#[serde(untagged)]` on a single variant makes just that one untagged, in which case it must be declared last.

**D verdict — [(a)][tags] for all four representations, [(b)][tags] for fixing the error quality.** D sum types plus a `@WireTag` / `@WireTag`-with-`@WireContent` / `@WireUntagged` trio (and `@WireOther`) is a direct port. Two D advantages are worth exploiting. First, **the tuple-variant restriction is an artifact, not a law**: it exists because serde must pick a `Serializer` call before it knows whether the format can host both a tag and a sequence, whereas wired knows the format at compile time and can either `static assert` with a specific message or pick a defined encoding. Second, **untagged error quality is fixable and is a differentiator**: wired can compute each variant's _discriminating field set_ at compile time and report "matched `Request` on `id` but field `method` was missing" instead of serde's dead end — and, better, `static assert` when two untagged variants are structurally ambiguous, catching at compile time a class of bug serde ships to runtime. This is one of the strongest "D can, Rust cannot" items in the survey.

---

## Transformations & validation

### Field-level conversion

| Attribute                   | Direction | Required signature                                        |
| --------------------------- | --------- | --------------------------------------------------------- |
| `serialize_with = "path"`   | ser       | `fn<S: Serializer>(&T, S) -> Result<S::Ok, S::Error>`     |
| `deserialize_with = "path"` | de        | `fn<'de, D: Deserializer<'de>>(D) -> Result<T, D::Error>` |
| `with = "module"`           | both      | a module exposing `serialize` and `deserialize`           |

**The critical limitation** is that the `deserialize_with` signature takes _only_ the deserializer. It has **no access to sibling fields, no access to the parent, and no access to any user-supplied context.** Context-dependent parsing — "decode `payload` according to whatever `encoding` said" — is not expressible. The documented workarounds are to hand-write the whole container's `Deserialize` impl, or to deserialize into a flat intermediate and post-process via `#[serde(from = "Intermediate")]`. Both abandon the declarative model at the first sign of real-world data.

### Type-level conversion

`#[serde(from = "F")]` reads `F` then calls `T::from`; `#[serde(try_from = "F")]` reads `F` then `T::try_from` and may fail; `#[serde(into = "I")]` clones into `I` before serializing; `#[serde(transparent)]` erases a single-field newtype.

```rust
#[derive(Deserialize)]
#[serde(try_from = "String")]
struct Email(String);                    // the validation point

impl TryFrom<String> for Email {
    type Error = &'static str;
    fn try_from(s: String) -> Result<Self, Self::Error> { /* reject non-emails */ }
}
```

`try_from` is the community's de-facto validation hook: it is the only place in serde where a domain rule can reject a value and produce an error the deserializer reports. `into` requiring `Clone` is a wart.

### `serde_with` — the adapter pattern

[`serde_with`][serde-with] is the most important _design_ lesson in the ecosystem, because it is a second, better layer bolted onto serde's `with` after the fact. The problem it solves: `serialize_with` takes a **function path**, and functions do not compose. Handling `Vec<Duration>` as seconds needs a new function; `Option<Vec<Duration>>` needs another; `BTreeMap<String, Vec<Duration>>` another. It is combinatorial.

The mechanism is **shadow traits on adapter types**:

```rust
pub trait SerializeAs<T: ?Sized> {
    fn serialize_as<S: Serializer>(v: &T, s: S) -> Result<S::Ok, S::Error>;
}
pub trait DeserializeAs<'de, T> {
    fn deserialize_as<D: Deserializer<'de>>(d: D) -> Result<T, D::Error>;
}
```

Because they are traits on types rather than functions, blanket impls make them compose — `impl<T, U: SerializeAs<T>> SerializeAs<Vec<T>> for Vec<U>` gives you `Vec<Adapter>` for free, recursively. The syntax then mirrors the type's shape, with `_` meaning "leave alone":

```rust
#[serde_as]                                        // MUST precede #[derive]
#[derive(Serialize, Deserialize)]
struct ApiConfig {
    #[serde_as(as = "DisplayFromStr")] port: u16,               // {"port": "8080"}
    #[serde_as(as = "DurationSeconds")] timeout: Duration,      // {"timeout": 30}
    #[serde_as(as = "BTreeMap<_, DisplayFromStr>")]
    limits: BTreeMap<String, u32>,                  // keys untouched, values stringified
    #[serde_as(as = "StringWithSeparator::<CommaSeparator, String>")]
    hosts: Vec<String>,                             // "a.com,b.com"
    #[serde_as(as = "OneOrMany<_>")] tags: Vec<String>,   // accepts "x" or ["x","y"]
    #[serde_as(as = "PickFirst<(_, DisplayFromStr)>")] id: u64, // number, then string
}
```

The adapter catalogue is the real product: `DisplayFromStr`, the `DurationSeconds`/`TimestampSeconds` families, `Map`/`Seq`/`EnumMap`, `VecSkipError`, `DefaultOnError`, `DefaultOnNull`, `NoneAsEmptyString`, `OneOrMany`, `PickFirst`, `StringWithSeparator`, `Bytes`, `BorrowCow`, `If`, `Same`, `_`. The lesson is that **representation choices are compositional over type structure**; attaching them to a function is a category error, attaching them to a type-shaped expression is correct — and they belong **at the use site**, not on the type, so the same `Duration` is seconds here and milliseconds there.

### Validation, and the cost of the split

serde has no validation layer. The ecosystem answer is [`validator`][validator] and its modern peer [`garde`][garde] (which adds first-class context via `#[garde(context(Config))]`, nested `inner` validation, and better error structure):

```rust
#[derive(Deserialize, Validate)]
struct SignupData {
    #[validate(email)] mail: String,
    #[validate(length(min = 1), custom(function = "unique_username"))] username: String,
    #[validate(range(min = 18, max = 20))] age: u32,
}
let data: SignupData = serde_json::from_str(s)?;   // step 1
data.validate()?;                                  // step 2 — you must remember
```

The split exists for defensible reasons: serde does _structural_ validation ("is this a parseable integer?") while these crates do _semantic_ validation ("is this age plausible?"), serde is fail-fast and single-error while validators collect and attribute all failures, and integrating would force serde to define an error-accumulation model it deliberately does not have. But it costs five concrete things:

1. **A forgettable second call.** `from_str` alone type-checks; nothing makes you validate. Invalid values exist as well-typed values in between.
2. **Two attribute vocabularies** on one struct, with no cross-checking between them.
3. **Errors do not unify** — different types, different paths, different rendering.
4. **No shared schema.** `#[validate(range(min = 18))]` is invisible to [`schemars`][schemars] unless restated as `#[schemars(range(min = 18))]`: the same constraint written three times.
5. **`try_from`, the workaround, costs a newtype per rule** and still cannot see sibling fields — so cross-field rules ("`end` must be after `start`") fall out entirely.

[`eserde`][eserde] is the ecosystem's attempt to fix this by validating _during_ deserialization; `facet-validate` is [facet][facet]'s.

**D verdict — [(a)][tags] for the plain conversions, [(a)][tags] for the sibling-access case (wired's headline win), and [(b)][tags] for the adapter algebra.** The plain case is covered by `@WireConvert!(Format, fn)`; type-level conversion needs no `Clone` in D (pass by `const ref`); `transparent` is trivial. For context, because wired generates the container's codec with full compile-time knowledge of every field, it can pass the partially-built struct to the converter:

```d
struct Payload
{
    Encoding encoding;
    @WireConvert!(Json, decodeBy!"encoding") ubyte[] payload;
}
```

with the hook receiving `ref const(Payload) sofar`. Two things need deliberate design: **field ordering** (a sibling-dependent field must be decoded after its dependency — computable as a compile-time topological sort, with a `static assert` on a cycle) and **input ordering** (JSON objects are unordered, so a late-arriving dependency forces buffering or a two-pass read). serde cannot do this at all. On adapters, D expresses the composition more directly than Rust does, because a template instantiated on a type _is_ the composition — no blanket impls, no coherence rules:

```d
@WireAs!(DisplayFromStr) ushort port;
@WireAs!(Map!(Same, DisplayFromStr)) Tuple!(string, uint)[] pairs;
@WireAs!(DurationSeconds) Duration timeout;
```

Introduce `@WireAs` as a compositional peer to the function-shaped `@WireConvert` **before** the CLI format locks the API, since the adapter set is immediately useful for argv (`StringWithSeparator` is `--tags a,b,c`, `OneOrMany` is repeatable-or-single, `DisplayFromStr` is essentially every scalar because argv is all text). And treat the validation split as serde's mistake to avoid: host `@WireValidate` in the same UDA vocabulary, run it inside the codec so an invalid value is never constructed, emit its constraint into the shape so `--help` prints the range and a JSON Schema carries it, and support the **cross-field** rules Rust's ecosystem cannot express declaratively at all.

---

## Errors & context

Serde errors carry a message and, at best, a line and column. They do **not** carry the _path_ to the failing field. [`serde_path_to_error`][path-to-error] wraps any `Deserializer` and tracks the field chain to produce a path like `dependencies.serde.version` — as a separate crate, with `serde_json_path_to_error` existing purely as a drop-in `serde_json` whose errors are good by default. That a wrapper crate is needed to answer "which field?" is a design admission.

The root cause is the `Visitor` model: by the time a `visit_*` method fails, the struct context lives on the _call stack_, not in a value, and serde's `Error` trait (`Error::custom` taking a `Display`) has nowhere to put it.

Serde also **aborts at the first error**. There is no "collect all problems" mode; [`eserde`][eserde] exists specifically to report multiple deserialization errors, and plans to fold validation in. For form, config, and CLI input, one-error-at-a-time is poor UX.

**Stateful deserialization** is the third gap. `DeserializeSeed` is serde's answer — a `Deserialize` that carries state, e.g. filling a pre-allocated buffer instead of a fresh `Vec`:

```rust
pub trait DeserializeSeed<'de>: Sized {
    type Value;
    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<Self::Value, D::Error>;
}
```

It exists but **cannot be derived** ([serde#881][serde-881]), does not compose through container types (a `Vec<T>` field cannot pass a seed to its elements), and [serde#650][serde-650] — open since 2016 — documents that libraries resort to a `thread_local` stack to smuggle state in, which the issue itself calls confusing and unsafe. Passing an arena, an interner, a symbol table, or a schema-version flag down a deserialization tree is a known-bad experience.

**D verdict — [(a)][tags] for paths, [(b)][tags] for accumulation and context threading; none of these are walls in D, and wired must not repeat them.** Build the path into the error type from the start: an `Expected!(T, WireError)` where `WireError` carries a field-path (a `SmallBuffer` of segments), a byte offset, and the expected shape. This is nearly free in D, because the generated code knows the field name statically at every recursion step. Support accumulation (`SmallBuffer!WireError`) with fail-fast as the fast path — a CLI that reports all three bad flags at once is visibly better than one that reports the first. Thread context as an ordinary defaulted parameter (`ref Ctx ctx`, with a `void`/empty default so it is zero-cost when unused) using the repo's standard shell-with-hooks shape: `static if (is(Ctx == void))` selects the stateless path. The argv relevance is direct: parsing `--config` may need the already-parsed `--profile`, a CLI parser needs an arena for `SmallBuffer` storage, and `@nogc` argv parsing _requires_ caller-supplied storage, which is precisely a seed. Error quality is not optional for a CLI either — "invalid value 'abc' for `--concurrency`: expected integer" is table stakes, and "unknown flag `--verbse`, did you mean `--verbose`?" needs the whole legal key set, which the next section shows wired has and serde does not.

---

## Metadata, derivations & extensibility

### `flatten` and the `deny_unknown_fields` collision

```rust
#[derive(Serialize, Deserialize)]
struct Response {
    limit: u64,
    #[serde(flatten)]
    pagination: Pagination,          // its fields appear inline
    #[serde(flatten)]
    extra: HashMap<String, Value>,   // catch-all for everything unclaimed
}
```

Serializing splices the inner struct's fields into the outer map. Deserializing buffers _all_ keys into a `Content` map, claims the recognized ones, and hands the remainder to each flattened field via a `FlatMapDeserializer`.

**`flatten` is incompatible with `deny_unknown_fields`** — documented, and tracked in [serde#1358][serde-1358] and [serde#1600][serde-1600]. Neither the embedding struct nor the flattened struct may use it. The reason is exactly [the structural difference](#the-one-structural-difference-that-drives-everything): the outer derive does not know `Pagination`'s field names, so at codegen time it cannot compute the union of legal keys, and at runtime it has already handed the leftovers away and can no longer distinguish "claimed by the inner struct" from "genuinely unknown". A subtler second cost: `flatten` forces `deserialize_any` on the flattened field, so the format must be self-describing and the buffered values are typed by the _input's_ syntax rather than the target field's type — which is why flatten breaks on `bincode`/`postcard` entirely.

### Escape hatches

`deny_unknown_fields` errors on unrecognized keys; `bound = "T: MyTrait"` overrides the inferred `where` clause; `crate = "..."` names the serde path for re-exported derives; `expecting = "..."` sets the human-readable expectation string; `variant_identifier`/`field_identifier` derive an identifier enum accepting string _or_ integer keys; `getter`/`remote` support deriving for a **foreign** type.

`bound` exists purely to work around a derive-macro deficiency: serde infers `T: Serialize` for every type parameter, which is wrong when `T` appears only inside an associated type or a `PhantomData`, and you then hand-write the clause. **Remote derive** works around the orphan rule — you write a mirror struct annotated `#[serde(remote = "std::time::Duration")]`, repeat the foreign type's field list by hand with `getter` accessors for private fields, and target it via `with`. Nothing checks that the mirror stays in sync, and you cannot deserialize the remote type at top level without a newtype wrapper.

### Schema generation: `schemars`

```rust
#[derive(JsonSchema, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    #[serde(default)]
    #[schemars(range(min = 1, max = 65535), description = "listening port")]
    port: u16,
}
```

[`schemars`][schemars] derives `JsonSchema` and — the key move — **reads the `#[serde(...)]` attributes directly** off the same type, so `rename_all`, `rename`, `default`, `skip`, `flatten`, and the enum representations shape the emitted schema without restating them. That it can do this while serde's own derive cannot see through a type boundary is instructive: reading another macro's attribute on the _same item_ is a syntactic read the proc macro is allowed; a cross-type lookup is not.

Where the single-source-of-truth story leaks: schemars documents that generated schema structure may change between versions and does not consider that breaking, so it is not a stable contract; `untagged` enums produce an `anyOf` with no discriminator, inheriting serde's poor error attribution; and — the load-bearing one — **anything expressed as a function is opaque**. `deserialize_with = "from_hex"`, `default = "default_port"`, `skip_serializing_if = "is_empty"`, `try_from`: the schema generator sees a path, not semantics, and must fall back to a permissive schema or a manual override.

### Summary: what D can express that Rust cannot

Ranked by leverage for wired.

| #   | Capability Rust cannot express                                        | Why D can                                     | Verdict     |
| --- | --------------------------------------------------------------------- | --------------------------------------------- | ----------- |
| 1   | Sibling-field access during decoding (context-dependent parsing)      | codec generated with all fields visible       | [(a)][tags] |
| 2   | `flatten` together with `deny_unknown_fields`                         | transitive key set computable at compile time | [(a)][tags] |
| 3   | Cross-field validation and constraint groups, checked at compile time | full type graph plus `static assert`          | [(a)][tags] |
| 4   | Compile-time rejection of ambiguous untagged variants                 | discriminating-field sets computable          | [(b)][tags] |
| 5   | Statically-typed flatten (works on non-self-describing formats)       | no `deserialize_any` needed                   | [(b)][tags] |
| 6   | An **open** data model extended per format (argv count/positional)    | format is a compile-time parameter; DbI       | [(b)][tags] |
| 7   | Zero-cost context/seed threading                                      | defaulted `ref Ctx` plus `static if`          | [(b)][tags] |
| 8   | Static verification that a foreign-type mirror matches the real type  | `__traits(allMembers)` on the foreign type    | [(a)][tags] |
| 9   | Help text from doc comments in a _semantic_ (non-macro) system        | `__traits(docComment)`                        | [(a)][tags] |
| 10  | [facet][facet]'s reflection benefits at serde's speed                 | CTFE shape feeding specialized codegen        | [(b)][tags] |

**D verdict — [(a)][tags] to implement flatten, and [(a)][tags] to _fix_ it; the metadata story is where D pulls furthest ahead.** Because `__traits(allMembers, Pagination)` is available while generating `Response`'s codec, wired can compute the **complete transitive set of legal keys across the flatten boundary at compile time**. That makes `@WireFlatten` and `@WireDenyUnknown` fully compatible, lets the unknown-field error carry a did-you-mean suggestion computed against the whole union, and makes the flattened field's decode **statically typed** — so wired's flatten works on non-self-describing formats, which serde's fundamentally cannot. For argv this is the core mechanism, not a nicety: `clap`'s `#[command(flatten)]` (shared `--verbose`/`--quiet` groups spliced into many subcommands) is exactly this, and it _must_ coexist with rejecting unknown flags. `bound` is a non-concept in D — template attribute inference and `if` constraints already do the right thing. **Remote derive is a non-problem**: D has no orphan rule for templates, so `wired.serialize!(Json)(x)` works on any `x`, and where a foreign type needs policy, an external policy table (a UDA-annotated mirror or an `AliasSeq` of type-policy pairs at the call site) can be `static assert`-checked against `__traits(allMembers, ForeignType)`, catching the drift serde silently permits; `getter` is unnecessary because D `@property` accessors are discoverable by introspection. Finally, take schemars' leak as a rule: **wired's policy attributes should be data, not function pointers, wherever possible.** `@WireDefault(8080)` is introspectable by a schema or help generator; `@WireDefault!defaultPort` is not. This is directly load-bearing for the CLI format, where `--help` text _is_ a schema rendering — a default you can print, a range you can print, an enum whose values you can list — and D additionally has `__traits(docComment, member)`, so wired can pull help prose from ddoc, which serde discards entirely.

---

## Strengths

- **The `N + M` insight itself.** A fixed intermediate model is the right architecture, and it is why one `#[derive]` gives you JSON, YAML, TOML, MessagePack, CBOR, and a dozen binary formats at once.
- **Zero-cost in the common case.** Monomorphized codecs with no intermediate `Value` tree; `serde_json` is competitive with hand-written parsers.
- **Genuinely bidirectional, direction-aware attributes.** One declaration yields both directions, with `rename(serialize, deserialize)`, `skip_serializing`/`skip_deserializing`, and deserialize-only `alias` where the asymmetry is real.
- **Four enum representations,** covering externally, internally, adjacently tagged and untagged — a more complete discrimination vocabulary than most ecosystems ship.
- **Zero-copy deserialization** with a principled transient/borrowed/owned trichotomy that any serious codec design has to reckon with.
- **`no_std` / `alloc`-free operation** for the feature subset that needs no buffering, plus enormous ecosystem gravity: nearly every Rust data crate implements the traits, so interop is essentially free.

## Weaknesses

- **The model is fixed at 29 types** ([serde#1556][serde-1556]) — richer formats cannot round-trip, and the escape hatch is a magic-named `newtype_struct` whose name `visit_newtype_struct` does not even receive.
- **No cross-field visibility anywhere.** `deserialize_with` sees only a deserializer; cross-field validation and context-dependent decoding require abandoning the derive.
- **`flatten` is incompatible with `deny_unknown_fields`** and forces `deserialize_any`, breaking on non-self-describing formats.
- **Untagged enum errors are uninformative** — `data did not match any variant of untagged enum X`, full stop — and structurally ambiguous variants are a runtime surprise.
- **Errors carry no field path** without a third-party wrapper crate, and deserialization is fail-fast with no accumulation mode.
- **Stateful deserialization is painful**: `DeserializeSeed` cannot be derived, does not compose through containers, and provokes `thread_local` hacks.
- **No reflection, no schema, and doc comments discarded.** You cannot ask a type for its field list; anything schema-shaped needs a second derive and a second attribute vocabulary, and help-rendering consumers get nothing.
- **No validation layer,** with `try_from` as a newtype-per-rule workaround, and the split costing an easily-forgotten second call plus triplicated constraints.
- **Compile time and code size** scale with the number of (type × format) pairs, since everything is monomorphized.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                             | Trade-off                                                                                            |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| A fixed intermediate data model of 29 types                   | Turns `N × M` pairings into `N + M`; each side implements one trait                   | Formats richer than the model cannot round-trip ([serde#1556][serde-1556]); no per-format extension  |
| Generic traits, monomorphized codecs                          | No dynamic dispatch, no intermediate tree; competitive with hand-written parsers      | Compile time and binary size scale per (type × format); no runtime introspection                     |
| Deserialization via `Visitor` with `deserialize_*` as a hint  | Lets a self-describing format choose the representation it actually found             | Failure context lives on the call stack, so errors carry no path; large boilerplate for custom impls |
| Derive as a syntactic proc macro                              | Ships without compiler support; usable by any crate                                   | Cannot see across a type boundary — the root of `flatten` versus `deny_unknown_fields`               |
| Cross-type composition deferred to runtime (`Content` buffer) | Makes `flatten`, `untagged`, and internal tagging work at all                         | Requires `alloc` and a self-describing format; loses static typing of the buffered values            |
| Attributes may name arbitrary functions                       | Maximum flexibility for conversion, defaults, and skip predicates                     | Constraints become opaque paths — [`schemars`][schemars] and `--help`-style consumers go blind       |
| No validation layer                                           | Structural and semantic validation are different concerns with different error models | Forgettable second call, two vocabularies, non-unifying errors, no cross-field rules                 |
| Fail-fast, single error                                       | Simplest contract; no accumulation model to define                                    | Poor UX for form, config, and CLI input; [`eserde`][eserde] exists to work around it                 |
| Enum representation as an explicit four-way choice            | Matches the shapes real APIs use, from JSON-flat to Haskell-adjacent                  | `untagged` requires buffering and produces the ecosystem's worst error message                       |
| `'de` lifetime for zero-copy                                  | Borrowing from the input buffer with a compiler-checked safety proof                  | Lifetime ceremony in every borrowing type; escapes still force allocation                            |

---

## Sources

- Official docs: [data model][data-model] · [container][container-attrs] / [field][field-attrs] / [variant][variant-attrs] attributes · [enum representations][enum-repr] · [lifetimes and zero-copy][lifetimes] · [remote derive][remote-derive] · [serde-rs/serde][repo]
- Issues: [#650 stateful deserialization][serde-650] · [#881 derive stateful (de)serialization][serde-881] · [#1358 `flatten` + internal tag + `deny_unknown_fields`][serde-1358] · [#1556 richer types than the data model][serde-1556] · [#1600 `deny_unknown_fields` with flattened untagged enum][serde-1600]
- Ecosystem: [`serde_with`][serde-with] · [`schemars`][schemars] · [`serde_path_to_error`][path-to-error] · [`validator`][validator] · [`garde`][garde] · [`bincode`][bincode] · [`serde_describe`][serde-describe]
- Commentary: [eserde: don't stop at the first deserialization error][eserde] · [Serde untagged enum errors are bad][untagged-blog] · [the run-up to v1.0 for Postcard][postcard] · [rkyv: zero-copy deserialization][rkyv]
- Related deep-dives: [facet][facet-dd] · [argv codecs][argv] · [Effect Schema][effect-schema] · [Pydantic][pydantic] · [msgspec / cattrs][msgspec] · [ZIO Schema][zio] · [circe / Aeson][circe] · [Haskell codecs][haskell] · [invertible syntax][invertible] · [ATD (OCaml)][atd]
- Catalog: [index][index] · [concepts][concepts] · [comparison][comparison] · [`sparkles:wired` baseline][baseline]

<!-- References -->

[repo]: https://github.com/serde-rs/serde
[site]: https://serde.rs/
[docs]: https://docs.rs/serde/latest/serde/
[crate]: https://crates.io/crates/serde
[data-model]: https://serde.rs/data-model.html
[container-attrs]: https://serde.rs/container-attrs.html
[field-attrs]: https://serde.rs/field-attrs.html
[variant-attrs]: https://serde.rs/variant-attrs.html
[enum-repr]: https://serde.rs/enum-representations.html
[lifetimes]: https://serde.rs/lifetimes.html
[remote-derive]: https://serde.rs/remote-derive.html
[serde-650]: https://github.com/serde-rs/serde/issues/650
[serde-881]: https://github.com/serde-rs/serde/issues/881
[serde-1358]: https://github.com/serde-rs/serde/issues/1358
[serde-1556]: https://github.com/serde-rs/serde/issues/1556
[serde-1600]: https://github.com/serde-rs/serde/issues/1600
[serde-with]: https://docs.rs/serde_with/latest/serde_with/
[schemars]: https://docs.rs/schemars/latest/schemars/
[path-to-error]: https://docs.rs/serde_path_to_error
[validator]: https://crates.io/crates/validator
[garde]: https://docs.rs/garde/latest/garde/
[eserde]: https://mainmatter.com/blog/2025/02/13/eserde/
[untagged-blog]: https://www.gustavwengel.dk/serde-untagged-enum-errors-are-bad
[postcard]: https://jamesmunns.com/blog/postcard-1-0-run/
[bincode]: https://docs.rs/bincode/latest/bincode/
[serde-describe]: https://docs.rs/serde_describe
[rkyv]: https://rkyv.org/zero-copy-deserialization.html
[facet]: https://github.com/facet-rs/facet
[facet-dd]: ./facet.md
[argv]: ./argv-codecs.md
[effect-schema]: ./effect-schema.md
[pydantic]: ./pydantic.md
[msgspec]: ./msgspec-cattrs.md
[zio]: ./zio-schema.md
[circe]: ./circe-aeson.md
[haskell]: ./haskell-codecs.md
[invertible]: ./invertible-syntax.md
[atd]: ./ocaml-atd.md
[index]: ./index.md
[concepts]: ./concepts.md
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[comparison]: ./comparison.md
[baseline]: ./wired-baseline.md
