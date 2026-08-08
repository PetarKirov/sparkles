# msgspec & cattrs (Python)

The other two corners of the model-centric design space [Pydantic][pydantic] anchors: **msgspec** keeps policy on the type but admits only features that survived a performance review, and **cattrs** moves policy off the type entirely, onto a converter object. Read together they isolate the one question the school actually disagrees about — _where does wire policy live_ — and each answers it with evidence.

| Field                  | msgspec                                                                        | cattrs                                                                                  |
| ---------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| Language               | Python (3.9+), C extension                                                     | Python (3.8+), pure Python with generated hooks                                         |
| License                | BSD-3-Clause                                                                   | MIT                                                                                     |
| Repository             | [msgspec/msgspec][ms-repo]                                                     | [python-attrs/cattrs][ct-repo]                                                          |
| Documentation          | [msgspec.dev][ms-docs]                                                         | [catt.rs][ct-docs]                                                                      |
| Category / tier        | Schema-guided strict decoder — **type-side policy** ([tier vocabulary][tiers]) | Converter-driven (un)structuring — **converter-side policy** ([tier vocabulary][tiers]) |
| First release / Status | `0.1.0`, 2021 · `0.19.x` line · actively maintained                            | 2016 · CalVer since `22.1.0` · actively maintained, the reference `attrs` companion     |
| Policy lives on        | the type — `Struct` class keyword arguments and `Annotated[T, Meta(...)]`      | a `Converter` object — registered hooks, `override()`, `preconf` presets                |
| Codec built            | a C decoder driven directly by the type annotation; decoding **is** validation | generated per-type hook functions, selected by predicate over types                     |

> [!NOTE]
> Both are read here as **expressiveness benchmarks for [`sparkles:wired`][baseline]**. The pairing is deliberate: msgspec supplies the primitives (`Raw`, tag configuration, strict-by-default) that make [Pydantic's][pydantic] most valuable ideas implementable, while cattrs supplies the counter-argument that type-side policy is the wrong default at all. The resolution `wired` needs is in the last section, and the cross-library synthesis is in [comparison][comparison].

---

## Overview

### What it solves

**msgspec** targets the networked-service case: decode a message, validate it against a schema, and pay as little as possible for both. Its thesis is that these are one operation, not two — a decoder that already walks the bytes can check the schema for free while it does so:

> _"Zero-cost schema validation using familiar Python type annotations. In benchmarks msgspec decodes and validates JSON faster than `orjson` can decode it alone."_ — [msgspec documentation][ms-docs]

**cattrs** targets a different pain: that serialization concerns leak into data models and never leave. Its answer is to make the model inert and put every wire decision in a converter object, which can be swapped, subclassed, or held two of at once:

> _"Because validation belongs to the edges."_ … _"cattrs does much more with a focus on functional composition and not coupling your data model to its serialization and validation rules."_ — [cattrs documentation][ct-docs]

### Design philosophy

msgspec's discipline is subtractive. Where Pydantic has three alias axes, msgspec has `rename` plus a per-field `name` override; where Pydantic has four validator modes, msgspec has a single `dec_hook`. Every retained feature earns its place, which makes msgspec a good filter: what it kept is what a fast implementation can afford, and the two things it kept that Pydantic lacks — `Raw` and configurable tag _generation_ — are both enabling primitives rather than conveniences.

cattrs' discipline is architectural, and the docs enforce it even against their own convenience API. `Annotated[int, cattrs.override(rename='class')]` exists, and carries a warning:

> _"One of the fundamental design decisions of cattrs is that serialization rules should be separate from the models themselves; by using this feature you're going against the spirit of this design decision."_ — [Customizing (un)structuring][ct-cust]

---

## How it works

msgspec derives everything from the annotation. A `Struct` subclass declares fields, class keyword arguments set aggregate-level policy, and `Annotated[T, Meta(...)]` attaches constraints to types:

```python
import msgspec

class Example(msgspec.Struct, rename="camel", omit_defaults=True, forbid_unknown_fields=True):
    field_one: int
    z: int = msgspec.field(name="field_z")                    # per-field override beats rename
    b: uuid.UUID = msgspec.field(default_factory=uuid.uuid4)
    version: ClassVar[str] = "1.0"                            # excluded from the wire form

msgspec.json.decode(data, type=Example)
```

cattrs derives nothing from the class. A `Converter` holds a registry of hooks, and `cattrs.gen` generates a specialised function per type on first encounter:

```python
from cattrs.gen import make_dict_structure_fn, make_dict_unstructure_fn, override

c = Converter()
c.register_unstructure_hook(datetime, lambda v: v.isoformat())

unst = make_dict_unstructure_fn(ExampleClass, c,
        klass=override(rename="class"),           # 'class' is a Python keyword
        an_int=override(omit=True),
        b=override(omit_if_default=True))
```

The override vocabulary — `rename`, `omit`, `omit_if_default`, `struct_hook`/`unstruct_hook` — is _the same vocabulary_ as Pydantic's `Field()` and msgspec's `field()`. The difference is purely **where it is written**.

---

## Schema model & bidirectionality

msgspec's schema is the type, full stop: `msgspec.json.decode(data, type=T)` and `msgspec.json.encode(v)` are the whole surface, with `msgspec.json.schema(T)` deriving JSON Schema as a third fold. Two consequences matter more than the API.

First, **partial schemas are free**. Declare three fields and a thirty-field document decodes at the cost of three; unknown keys are ignored by default and fields with defaults absorb both missing-in-old-data and new-in-new-data. msgspec names this and sells it:

> _"msgspec supports "schema evolution". Messages can be sent between clients with different schemas without error, allowing systems to evolve over time."_ — [Why msgspec?][ms-why]

Second, **`Raw` makes decoding pausable**:

```python
class Message(msgspec.Struct):
    sender: str
    payload: msgspec.Raw          # kept as bytes, undecoded

msg = msgspec.json.decode(data, type=Message)
body = msgspec.json.decode(msg.payload, type=WhateverSenderImplies)
```

The format-neutral middle is public API rather than an internal seam: `msgspec.to_builtins(v)` and `msgspec.convert(obj, T)` sit between the type and any of the JSON, MessagePack, YAML and TOML front-ends, so one `Struct` serves every format and a user can add a format without touching the engine.

cattrs splits the two directions into two independently registered functions, `structure` and `unstructure`, which do not have to be inverses and frequently are not. That is the honest consequence of converter-side policy: nothing enforces round-tripping, and nothing pretends to.

> **D verdict:** `Raw` is [**(b)** — CTFE effort][tags] and high value. In D it is a borrowed slice of the input — `const(ubyte)[]` or a `Span` — which fits the repo's arena/borrowed-span idiom (cf. `sparkles:diff`'s texts-borrowed-as-spans) and costs nothing. It unlocks three things at once: two-phase decode where a later field determines an earlier field's type, callable discriminators (peek at the raw form, pick the tag, then decode), and unknown-field preservation with fidelity. For argv, `Raw` is the trailing `string[]` handed to a subcommand parser once the subcommand is known. **Build `Raw` before building callable discriminators; it is the enabling primitive.** Partial decoding is [**(a)** — struct + UDA][tags] and free, but is worth stating as an explicit design invariant — **never materialise what the type did not ask for** — because it is _lost_ the moment the engine builds a generic DOM first; for a CLI it is how a top-level parser consumes global flags and leaves the rest. The public format-neutral middle is [**(a)**][tags] and is already `wired`'s architecture, so msgspec is confirmation rather than novelty; the part to steal is that the middle is _exposed_, not hidden.

---

## Naming, optionality & defaults

msgspec's aggregate keywords are a compact superset of what most programs need:

| Option                                                            | Meaning                                                                       |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `rename=`                                                         | `"lower"`, `"upper"`, `"camel"`, `"pascal"`, `"kebab"`, a dict, or a callable |
| `field(name=)`                                                    | per-field override, beats `rename`                                            |
| `omit_defaults`                                                   | skip fields equal to their default                                            |
| `forbid_unknown_fields`                                           | error on unknown keys (default: ignore)                                       |
| `array_like`                                                      | encode as `[v1, v2]` instead of a keyed object                                |
| `ClassVar`                                                        | exclude a class-level constant from the field set                             |
| `frozen` / `order` / `eq` / `kw_only` / `gc` / `weakref` / `dict` | value semantics and CPython layout tuning                                     |

A callable `rename` may return `None` to skip a field, which folds "exclude" into the naming mechanism. **`array_like=True` deserves separate attention**: it says this aggregate's wire form is _positional_ rather than keyed, and combined with a tag it yields `["Get", "k"]`.

cattrs expresses the same axes per class at the converter, and additionally reaches into `attrs` metadata that the class already carries: `_cattrs_use_alias=True` adopts `attrs` field aliases as keys, `_cattrs_include_init_false=True` opts `init=False` fields back in, and `_cattrs_forbid_extra_keys=True` is the `forbid_unknown_fields` equivalent. Notably `omit_if_default` is settable per class _and_ per attribute, with the per-attribute value winning — the same explicit-precedence discipline Pydantic exposes as `alias_priority`.

The open metadata channel underneath both is `attrs`/`dataclasses` `field(metadata={...})`: an untyped, arbitrary mapping the stdlib never interprets, namespaced by convention. It is the only reason cattrs and every other `attrs`-consuming library can co-annotate a class without knowing about each other.

> **D verdict:** `rename` and per-field `name` are [**(a)**][tags] — `wired`'s `@WireCase!F` already covers the enumerated cases, and the dict and callable forms are free at CTFE. `omit_defaults` and `forbid_unknown_fields` are [**(a)**][tags] policy flags. `array_like` is [**(a)**][tags] and **is the positional-argument feature**: for argv it means "these fields are consumed positionally, in declaration order" — `cp SRC DST`. A CLI struct is _mixed_, though, with some fields positional and some keyed, so the right D generalisation is a per-field `@WirePositional!Cli` with the aggregate flag as an all-fields shorthand; msgspec needs no such generalisation because none of its formats are mixed. The value-semantics and CPython-layout keywords fall outside the tag scale — D structs already are what `frozen`/`order`/`eq` ask for, `kw_only` addresses a required-before-optional ordering constraint D does not have, and `gc`/`weakref`/`dict` are object-layout knobs with no analogue. The open metadata channel is [**(a)**][tags] and free, since D UDAs are strictly better — typed, compile-time-checked, namespaced by module rather than string convention — but it carries one obligation the Python ecosystem learned the hard way: **`wired` must ignore UDAs it does not recognise, never error on them**, or a struct can no longer carry an ORM's or a project's own annotations alongside `@WireName`.

---

## Sum types & discrimination

msgspec's tagged unions are configured by two inheritable keywords:

```python
class Get(msgspec.Struct, tag=True): key: str
class Put(msgspec.Struct, tag=True): key: str; val: str
msgspec.json.Decoder(Get | Put).decode(b'{"type":"Put","key":"k","val":"v"}')

class Base(msgspec.Struct, tag_field="op", tag=str.lower): ...
class Get(Base): key: str          # -> {"op": "get", ...}
```

`tag` may be `True` (use the class name), a `str`, an `int`, or **a callable applied to the class name**; `tag_field` names the discriminator key. Both are inherited, so a base class sets the convention once for a whole union. `tag=int` is what makes the mechanism usable for binary formats.

cattrs packages the same idea as a _strategy_ — a prepackaged converter configuration — and adds the one knob neither Pydantic nor msgspec offers:

> _"A default member can be specified to be used if the tag is missing or is unknown. This is useful for evolving APIs in a backwards-compatible way; an endpoint taking class `A` can be changed to take `A | B` with `A` as the default (for old clients which do not send the tag)."_ — [Strategies][ct-strat]

`configure_tagged_union` takes `tag_name` (default `_type`), `tag_generator` (class name, a class variable, or a dict lookup), and that `default`. Two further strategies round it out: `include_subclasses`, which dispatches over a class hierarchy as though the union of base and descendants had been requested — explicitly opt-in because _"there is not apparent universal good defaults for disambiguating the union type"_ — and `union_passthrough`, which handles unions of primitives and is pre-applied to the JSON and msgpack converters.

> **D verdict:** everything in msgspec's tag configuration is [**(a)**][tags] and pure CTFE, with the inheritance trick mapping to a mixin template applied to each member or a UDA on a common template. The comparison with Pydantic is the useful part: msgspec's tags are _generated by convention_ (`str.lower` of the class name) where Pydantic's are _declared per member_ (`Literal['cat']`), and D wants **both**, with the convention as default and a per-member override under the same explicit-beats-generated precedence rule as naming. The unknown-tag `default` fallback is [**(a)**][tags], one UDA (`@WireUnknownTag!Fallback`), and worth having: it is forward compatibility for a wire protocol, expressed in the schema. `include_subclasses` is outside the tag scale — a reference-semantics class-hierarchy problem that D value types model as `SumType` instead — and `union_passthrough` is [**(a)**][tags], being format-specialised primitive handling, i.e. the `Format` marker again.

---

## Transformations & validation

msgspec is **strict by default**, the opposite of Pydantic, and is right for a self-describing format: if JSON can express an integer, a string where an integer belongs is a bug.

```python
msgspec.json.decode(b'[1,2,"3"]', type=list[int])                # ValidationError
msgspec.json.decode(b'[1,2,"3"]', type=list[int], strict=False)  # [1, 2, 3]
```

Constraints arrive as `Annotated` metadata, in the same shape Pydantic uses — convergent evolution, which is evidence the shape is right:

```python
class Product(msgspec.Struct):
    name:  Annotated[str,   msgspec.Meta(min_length=1, max_length=100)]
    price: Annotated[float, msgspec.Meta(ge=0, multiple_of=0.01)]
    sku:   Annotated[str,   msgspec.Meta(pattern=r'^\w{3}-\d{4}$')]
```

The single escape hatch is a pair of converter-level hooks, `enc_hook(obj)` and `dec_hook(type, obj)`, attached to the **encoder/decoder rather than the type**. This is the one place msgspec agrees with cattrs, and for the same stated reason: **you cannot annotate a type you do not own.**

cattrs makes that the whole architecture. Hooks are registered by type, but because `singledispatch` uses `issubclass()` — which fails for `list[int]`, `Literal`, protocols and `Annotated` — the useful mechanisms are the two above it: predicate hooks, and **hook factories**.

> _"Hook factories are higher-order predicate hooks: they are functions that produce hooks."_ — [Customizing (un)structuring][ct-cust]

```python
c.register_structure_hook_factory(
    has,                                            # predicate: is it an attrs class?
    lambda cl: make_dict_structure_fn(cl, c, _cattrs_forbid_extra_keys=True))

@c.register_structure_hook_factory(is_mutable_sequence)
def strict_list_hook_factory(type, converter):
    list_hook = list_structure_factory(type, converter)   # wrap the existing factory
    def strict_list_hook(value, type):
        if not isinstance(value, list):
            raise ValueError("Not a list!")
        return list_hook(value, type)
    return strict_list_hook
```

A hook factory is a function from _type_ to _codec_, selected by a predicate over types — and factories compose by wrapping. Registration order is load-bearing (predicate hooks are checked in reverse registration order; simpler types must be registered before the complex types that depend on them), which is a genuine ergonomic wart.

> **D verdict:** strict-by-default is [**(a)**][tags] as a per-format policy default with per-call override — and note that msgspec and Pydantic choosing _opposite_ defaults for different media is the argument for making the default a property of the `Format` marker rather than of the library. Constraints are [**(a)**][tags], as in Pydantic. `dec_hook`/`enc_hook` are [**(b)**][tags]: a `Hooks` (or `Policy`) template parameter whose members are matched by DbI — `static if (__traits(compiles, Hooks.decode!T(...)))` — which beats msgspec's single runtime function doing `if type is X` dispatch, because D resolves per type at compile time with no branch. Both mechanisms are needed, not one: the DbI-first alternative the repo already prefers (if `T` has `fromWire`/`toWire`, use them) covers only types you own. Hook factories are [**(a)**/**(b)**][tags] and **are Design by Introspection, exactly** — the predicate is the template constraint, the factory is the template body, reverse registration order is template specialisation ordering, and factory composition is a template instantiating a more general template and wrapping it. cattrs is laboriously reconstructing at runtime what the D compiler supplies, so the transferable item is not the mechanism but the organising principle: **codec selection should be predicate-over-types, open to user extension, and composable by wrapping**, rather than a closed `static if` chain only the engine's author can extend. If `wired`'s dispatch is a closed chain today, opening it into user-extensible trait dispatch is the single highest-leverage refactor cattrs suggests — see the repo's [DbI guidelines][dbi].

---

## Errors & context

msgspec's `ValidationError` carries the expected type, the found type, and a JSONPath-ish **location**: ``Expected `str`, got `int` - at `$.groups[1]` ``. A hook raising `TypeError` or `ValueError` is converted into the same error with that context attached, so third-party conversions get located errors for free.

cattrs' detailed-validation mode, on by default since `22.1.0`, takes the other approach and collects rather than fails fast: structuring errors are gathered field-by-field (or key/index-by-key/index for sequences and mappings) and raised together as a `BaseValidationError`, which is a PEP 654 `ExceptionGroup` — _"in essence, `ExceptionGroups` are trees of exceptions"_ — with each inner exception's `__notes__` naming its field, key or index. `cattrs.transform_error()` flattens the tree into a list of messages, and `detailed_validation=False` reverts to bubbling the first failure. The trade is stated plainly: detailed structuring hooks are _"slightly slower but produce richer and more precise error messages"_; unstructuring is unaffected.

Neither library has Pydantic's per-call context object. msgspec's nearest equivalent is a closure captured by an `enc_hook` over its encoder; cattrs' is **the converter itself** — a converter carrying configuration _is_ a context, but one bound permanently at construction, so per-call variation means constructing a second converter.

> **D verdict:** located errors are [**(b)**][tags] and are the part worth engineering. This is engine plumbing rather than user-facing API, and it is the difference between a usable and an unusable message — `$.groups[1]` for JSON, `--server.port` for argv. cattrs' tree-of-errors is [**(c)** — value-level composition][tags] and largely _not_ what a `@nogc nothrow` D codec on [`Expected!(T, E)`][expected] should copy wholesale, since accumulating a tree implies allocation; the transferable half is the **policy split** — fail-fast versus collect-all is a per-call decision, not a library-wide one, and a CLI wants collect-all so it can report every bad flag at once. cattrs' converter-as-context is the negative result that justifies Pydantic's design: policy bound at converter-construction time cannot vary per call, so a statically typed `Ctx` template parameter threaded through both directions ([**(b)**][tags]) beats both Python answers.

---

## Metadata, derivations & extensibility

msgspec derives JSON Schema from the same annotations (`msgspec.json.schema(T)`, `schema_components` for multi-root documents), with `Meta`'s `title`/`description`/`examples`/`extra_json_schema` feeding it, and exposes the type model itself through `msgspec.inspect` — a reified description of a type usable for building other tooling. That is the same "schema as a value, artifacts as folds over it" structure Pydantic reaches by a different route.

cattrs' extensibility is the converter, layered: `preconf` ships ten pre-wired converters, one per serialization library, each encoding how that format natively represents the awkward types.

| Format    | `bytes`       | `datetime`                | sets               | notes                 |
| --------- | ------------- | ------------------------- | ------------------ | --------------------- |
| `json`    | base85 string | ISO 8601 string           | list → set         | Counters become dicts |
| `orjson`  | base85 string | passed through (RFC 3339) | list → set         | integer range limited |
| `msgspec` | base64 native | passed through            | msgspec handles    | strict by default     |
| `msgpack` | native        | UNIX timestamps           | list → set         | timestamp floats      |
| `cbor2`   | native        | text/timestamp tag        | **sets preserved** | big integers          |
| `bson`    | native        | native, no microseconds   | list → set         | string keys only      |
| `pyyaml`  | native        | native strings            | frozensets → lists | namedtuples → arrays  |
| `tomlkit` | base85 string | passed through            | list → set         | tuples become lists   |

The table is the argument. `bytes` is base85 in one converter and base64 in another **for the same Python type and the same program** — so the representation is a property of the _format_, not of the type and not of the application. cattrs discovered this and had to bolt it on as ten hand-maintained presets.

Two smaller extension points close the loop. `use_class_methods` lets a class supply `_structure()`/`_unstructure()` with the converter falling back to its default when they are absent — the DbI "optional primitive" pattern, arrived at independently. And `attrs`' `converter=` per-field coercion is a third place a transformation can live, which is precisely the problem: msgspec, cattrs, and `attrs` each offer a legitimate home for the same rule, and nothing arbitrates between them.

That is the lesson to take, and it is the one thing neither library states outright: **the layers need a documented precedence order.** For `wired`, with UDAs on the type _and_ a `Policy` parameter for types you do not own:

```text
per-call argument  >  Policy hooks  >  UDAs on the type  >  format defaults
```

`Policy` above UDAs, so a caller can override a third-party type _and_ one of their own. That ordering also subsumes cattrs' entire strategy layer: `configure_tagged_union`, `include_subclasses` and `use_class_methods` are pre-packaged converter configurations, which in D are pre-packaged mixin templates.

> **D verdict:** per-format type representation is [**(a)**][tags] and is **the strongest external validation of `wired`'s `Format`-marker design in the whole survey** — `@WireRepr!Json` versus `@WireRepr!Msgpack` on one field is free where cattrs needs a hand-maintained preset per library. Keep it. `use_class_methods` is [**(a)**][tags] and already idiomatic D. JSON Schema derivation and `msgspec.inspect` are [**(b)**][tags] and reinforce the [CTFE `WireSchema` recommendation][pydantic]. The precedence ladder is [**(a)**][tags] to implement and the item most likely to be got wrong by omission: it costs one documented rule now and is unfixable later, because every hook written against an undocumented order encodes the accident.

---

## Strengths

- **msgspec — decoding is validation.** No second pass, no separate schema object; the annotation drives a C decoder that checks as it walks.
- **msgspec — `Raw`.** Delayed decoding as a first-class type, which is what makes callable discriminators, two-phase decode, and lossless unknown-field preservation implementable at all.
- **msgspec — one type, many formats,** with `to_builtins`/`convert` exposing the format-neutral middle as public API.
- **msgspec — tag generation is configurable and inherited,** so a base class sets a union's whole convention once; `tag=int` keeps binary formats usable.
- **cattrs — the model stays clean.** A third-party or generated class is serialized without being touched, and one class can have several wire contracts by holding several converters.
- **cattrs — hook factories are open extension.** Predicate-over-types selection that composes by wrapping, so users extend the codec set without patching the library.
- **cattrs — `preconf` documents what is format-specific,** and the tagged-union `default` gives forward compatibility no peer offers.
- **cattrs — error trees.** Every field's failure reported at once, with paths, and a flattener for compact output.

## Weaknesses

- **msgspec — a deliberately small vocabulary.** No alias choices, no alias paths, no per-field validators, no callable discriminators, no encode-only computed fields, no context.
- **msgspec — the single `dec_hook` is runtime type dispatch,** an `if type is X` chain that grows linearly with the custom types in a program.
- **msgspec — `array_like` is per-aggregate,** so a mixed positional/keyed wire form (which every CLI is) cannot be expressed.
- **cattrs — policy is scattered.** Reading a class tells you nothing about its wire form; you must find the converter that structures it.
- **cattrs — registration order is load-bearing,** with predicate hooks checked in reverse order and simple types needing registration before the complex types that use them.
- **cattrs — context is baked into the converter,** so per-call variation means a second converter.
- **cattrs — structure and unstructure are independent functions** with nothing enforcing that they are inverses.
- **Both — no provenance channel.** Neither can answer "was this field present in the input", so `omit_defaults` / `omit_if_default` are the closest available approximation and they conflate value with presence.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                   | Trade-off                                                                                   |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| msgspec: decoding **is** validation, in C                         | One walk over the bytes; no intermediate DOM, no second pass                | Every feature must be implementable in the decoder, which caps the vocabulary               |
| msgspec: strict by default, `strict=False` per call               | In a self-describing format, a string where an int belongs is a bug         | Callers reading legacy or stringly-typed data must opt out explicitly                       |
| msgspec: `Raw` as a real type                                     | Look-ahead without commitment, at the cost of a borrowed slice              | The caller must remember to decode it later; the type system does not force the second pass |
| msgspec: unknown fields ignored unless `forbid_unknown_fields`    | Schema evolution works by default; old and new clients interoperate         | Typos in input are silently dropped unless the flag is set                                  |
| msgspec: hooks on the encoder/decoder, not the type               | You cannot annotate a type you do not own                                   | One runtime dispatch function per codec, checked linearly                                   |
| cattrs: policy on a converter, never on the model                 | Third-party types work; one model can have many wire contracts              | Locality and discoverability are lost; nothing enforces bidirectionality                    |
| cattrs: hook factories — predicates producing codecs              | Open extension that composes by wrapping, covering generics and `Annotated` | Registration order becomes semantic, and dispatch is a runtime predicate scan               |
| cattrs: `preconf` converter per serialization library             | The representation of `bytes`/`datetime`/sets belongs to the format         | Ten presets to hand-maintain as the underlying libraries change                             |
| cattrs: detailed validation collecting an `ExceptionGroup`        | Report every field's failure at once, with paths                            | Structuring hooks measurably slower; opt out with `detailed_validation=False`               |
| cattrs: tagged-union `default` member for missing or unknown tags | An endpoint taking `A` can become `A \| B` without breaking old clients     | Silently accepts tags it does not understand, which hides genuine protocol drift            |

---

## Sources

- [msgspec/msgspec — GitHub repository][ms-repo] · [msgspec documentation][ms-docs]
- [Structs — class keywords, `rename`, `omit_defaults`, `array_like`, tags][ms-structs]
- [Usage — strict mode, `Raw`, `to_builtins`/`convert`, multi-format][ms-usage]
- [Extending — `enc_hook` / `dec_hook`][ms-ext]
- [Supported types — `Meta` constraints, `Annotated`][ms-types]
- [Why msgspec? — validation, application logic, schema evolution][ms-why]
- [JSON Schema generation][ms-schema] · [`msgspec.inspect` — the reified type model][ms-inspect]
- [python-attrs/cattrs — GitHub repository][ct-repo] · [cattrs documentation][ct-docs]
- [Customizing (un)structuring — hooks, predicates, hook factories, `override()`][ct-cust]
- [Strategies — `configure_tagged_union`, `include_subclasses`, `use_class_methods`][ct-strat]
- [Preconfigured converters — the per-format type-mapping table][ct-preconf]
- [Validation — detailed mode, `ExceptionGroup`, `transform_error()`][ct-val]
- Catalog siblings: [serde overview][index] · [concepts][concepts] · [Pydantic v2][pydantic] · [`serde` (Rust)][serde] · [`facet` (Rust)][facet] · [Effect Schema][effect] · [ZIO Schema][zio] · [circe & aeson][circe] · [Haskell codecs][haskell] · [invertible syntax][invertible] · [OCaml ATD][atd] · [argv codecs][argv] · [`wired` baseline][baseline] · [comparison][comparison]

<!-- References -->

[ms-repo]: https://github.com/msgspec/msgspec
[ms-docs]: https://msgspec.dev/
[ms-structs]: https://msgspec.dev/structs
[ms-usage]: https://msgspec.dev/usage
[ms-ext]: https://msgspec.dev/extending
[ms-types]: https://msgspec.dev/supported-types
[ms-why]: https://msgspec.dev/why
[ms-schema]: https://msgspec.dev/jsonschema
[ms-inspect]: https://msgspec.dev/inspect
[ct-repo]: https://github.com/python-attrs/cattrs
[ct-docs]: https://catt.rs/en/stable/index.html
[ct-cust]: https://catt.rs/en/stable/customizing.html
[ct-strat]: https://catt.rs/en/stable/strategies.html
[ct-preconf]: https://catt.rs/en/stable/preconf.html
[ct-val]: https://catt.rs/en/stable/validation.html
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[concepts]: ./concepts.md
[index]: ./index.md
[comparison]: ./comparison.md
[baseline]: ./wired-baseline.md
[pydantic]: ./pydantic.md
[serde]: ./serde.md
[facet]: ./facet.md
[effect]: ./effect-schema.md
[zio]: ./zio-schema.md
[circe]: ./circe-aeson.md
[haskell]: ./haskell-codecs.md
[invertible]: ./invertible-syntax.md
[atd]: ./ocaml-atd.md
[argv]: ./argv-codecs.md
[expected]: ../../guidelines/idioms/expected/index.md
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
