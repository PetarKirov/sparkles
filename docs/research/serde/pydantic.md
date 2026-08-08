# Pydantic v2 (Python)

The maximalist of the model-centric school: a type's fields carry the entire wire contract — names, defaults, constraints, coercion policy, discriminators, docs — and the whole public API is a library of `Annotated` metadata objects compiled into a reified _core schema_ that a Rust engine interprets.

| Field                  | Value                                                                                                                          |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Language               | Python (3.9+)                                                                                                                  |
| License                | MIT                                                                                                                            |
| Repository             | [pydantic/pydantic][repo] · [pydantic/pydantic-core][core-repo] (the Rust engine)                                              |
| Documentation          | [pydantic.dev/docs/validation][docs] (the `docs.pydantic.dev` host now `301`s here)                                            |
| Category / tier        | Model-centric runtime validator — **type-side policy** ([tier vocabulary][tiers])                                              |
| First release / Status | `v1.0` October 2019 · **`v2.0` June 2023** (the `pydantic-core` rewrite) · actively maintained                                 |
| Policy lives on        | the type — `Field()` arguments and `Annotated` metadata                                                                        |
| Codec built            | at import time, as a `CoreSchema` **value** handed to `pydantic-core` (Rust) which compiles it into a validator + a serializer |

> [!NOTE]
> This deep-dive is an **expressiveness benchmark for [`sparkles:wired`][baseline]**, not a recommendation to imitate Pydantic's architecture. Pydantic pays at runtime what D pays at compile time, and roughly a third of its surface exists purely to compensate for Python's lack of static types — see [Metadata, derivations & extensibility](#metadata-derivations--extensibility). Its companions in this catalog are [msgspec & cattrs][msgspec] (the other two corners of the same design space), [`serde`][serde] and [`facet`][facet] in Rust, and the synthesis in [comparison][comparison].

---

## Overview

### What it solves

A Python program that reads JSON gets `dict[str, Any]`: no attribute access, no type checking, no idea whether the document it was handed is the document it expected. Pydantic's answer is that **the class declaration is the schema** — annotate the fields, and the library derives a validator (wire form → instance, with coercion and constraint checking) and a serializer (instance → wire form) from the same declaration. Everything else in the library is an axis of control over those two derived functions.

Crucially it goes further than "parse into a struct". A field annotation carries _policy_, not just a type: which input names are accepted, which name is emitted, what the value must satisfy, whether coercion is allowed, when the field is omitted from output, and how the failure reads. That accumulation is why Pydantic is the right upper bound for a survey of serde expressiveness — it is the library that said yes to almost every capability, and the interesting question is which of those capabilities are real expressiveness and which are Python-shaped scaffolding.

### Design philosophy

Two commitments define v2. The first is that **metadata rides on the type, via `Annotated`, without disturbing the type**:

> _"As far as static type checkers are concerned, `name` is still typed as `str`, but Pydantic leverages the available metadata to add validation logic, type constraints, etc."_ — [Fields][docs-fields]

The second is that **every extension point is middleware-shaped** — a hook receives the rest of the pipeline as a callable handler and decides whether, when, and with what to invoke it. The docs state this explicitly about the deepest hook of all, schema generation itself:

> _"In both cases the API is middleware-like and similar to that of "wrap" validators: you get a `source_type` (which isn't necessarily the same as the class, in particular for generics) and a handler that you can call with a type to either call the next metadata in `Annotated` or call into Pydantic's internal schema generation."_ — [Custom types][docs-types]

Those two commitments compose into the architecture: a stack of `Annotated` metadata objects, each of which is a middleware over schema construction, folded into one `CoreSchema` value that is handed to Rust.

---

## How it works

`Field()` is the single declaration point for per-field policy. It is usable positionally or — preferably — inside `Annotated`, which is what makes a constraint reusable and composable rather than welded to one declaration site:

```python
from typing import Annotated
from pydantic import BaseModel, Field

class User(BaseModel):
    name: str = Field(alias='full_name')
    age: Annotated[int, Field(gt=0, le=150)]
    tags: list[Annotated[str, Field(min_length=1)]]   # constraint on the ELEMENT type
```

At class-creation time Pydantic walks the annotations, collects the metadata objects attached to each, and calls each one's `__get_pydantic_core_schema__` in turn — every metadata object being a middleware over the next — producing a single `CoreSchema`: a plain, JSON-shaped data structure describing the codec for the whole model. `pydantic-core` compiles that value into a validator object and a serializer object. Both directions come out of one description, which is why `model_json_schema(mode='validation')` and `model_json_schema(mode='serialization')` can legitimately differ.

Three call surfaces expose the result: `model_validate` / `model_validate_json` (decode), `model_dump` / `model_dump_json` (encode), and `model_json_schema` (derive). The last is the tell that the schema is genuinely reified — it is a third fold over the same artifact.

---

## Schema model & bidirectionality

The `CoreSchema` is the whole story. `__get_pydantic_core_schema__` returns a **data structure describing the codec**, and its constructors cover both directions in one value:

```python
from pydantic_core import core_schema

class Username(str):
    @classmethod
    def __get_pydantic_core_schema__(cls, source_type, handler) -> core_schema.CoreSchema:
        return core_schema.no_info_after_validator_function(cls, handler(str))
```

Note `handler(str)`: the hook calls _back_ into schema generation to build the inner schema, so schema construction is itself a wrappable pipeline. The constructor set includes `no_info_` / `with_info_` crossed with `before_` / `after_` / `wrap_` / `plain_validator_function`, plus `chain_schema`, `union_schema`, `is_instance_schema`, `typed_dict_schema`, and `plain_serializer_function_ser_schema` — and, tellingly, `json_or_python_schema`: **different codecs for different input media, declared inside the schema.**

**Bidirectionality is explicitly not symmetry.** `computed_field` makes a member of the wire form that is not a member of the class:

```python
class Rectangle(BaseModel):
    width: float
    height: float

    @computed_field
    @property
    def area(self) -> float:
        return self.width * self.height

Rectangle(width=4, height=5).model_dump()   # {'width': 4.0, 'height': 5.0, 'area': 20.0}
```

`area` appears in the serialization-mode JSON Schema and is absent from the validation-mode one. The encode field set and the decode field set are different sets, and the engine is built knowing that.

Round-trip fidelity for _unknown_ fields is a separate knob. `model_config = ConfigDict(extra=…)` is three-way — `'ignore'` (default, drop), `'forbid'` (reject), `'allow'` (keep) — and the third stores survivors in `__pydantic_extra__` (optionally typed) and **re-emits them on dump**. That is what makes a partial model usable as a proxy: read a document you only partly understand, edit the parts you do, and write it back without data loss.

> **D verdict:** the reified schema is the single most important structural idea in this survey and is [**(b)** — CTFE effort][tags], with D able to do it strictly better, since the analogue of "schema value compiled to a validator" is "CTFE-computed description → generated code" and the description need never exist at runtime. `wired` should compute an internal, introspectable `WireSchema` value from the UDAs — per-format names, types, constraints, defaults, docs, tags — and generate codecs _from that value_ rather than directly from `__traits(allMembers)`. Once the schema is a value, the argv decoder, the argv encoder, `--help` text, shell completions, man pages, JSON Schema for the config file, and `--dump-config` are seven folds over one artifact, mutually consistent by construction. `computed_field` is [**(a)** — struct + UDA][tags] (reflect over `@WireComputed` member functions alongside fields): cheap now and expensive later, because an engine that assumes one field list serves both directions has to be retrofitted. Unknown-field preservation is [**(a)**/**(b)**][tags] — `@WireExtra Raw[string] rest;`, using a borrowed-span `Raw` rather than `string[string]`, which already loses fidelity for a JSON number.

---

## Naming, optionality & defaults

Naming is a **three-way** split, because the decode name and the encode name are not always the same — you accept a legacy name for input but always emit the modern one:

```python
class User(BaseModel):
    name: str = Field(alias='full_name')                      # both directions
    age: int = Field(validation_alias='user_age')             # decode only
    email: str = Field(serialization_alias='contact_email')   # encode only
```

Two refinements matter more than the split itself. **`AliasChoices`** accepts N input names, first-match-wins, while the encode side keeps exactly one — the asymmetry a naive design gets wrong:

```python
first_name: str = Field(validation_alias=AliasChoices('first_name', 'fname', 'firstName'))
```

**`AliasPath`** reads a field from a _nested_ location in the wire form, and the two compose:

```python
class User(BaseModel):
    first_name: str = Field(validation_alias=AliasPath('names', 0))
    address:    str = Field(validation_alias=AliasPath('contact', 'address'))
    # AliasChoices('first_name', AliasPath('names', 0)) accepts flat OR nested
```

This is the most under-appreciated capability in the survey: it **decouples the class's shape from the wire form's shape** without an intermediate DTO plus a hand-written mapping function. Every other library surveyed forces the DTO. Pydantic supports it on the validation side only.

Whole-model naming policy comes from `alias_generator` (with `to_camel` / `to_pascal` / `to_snake` helpers), and the collision between a generator and an explicit alias is resolved by an **explicit `alias_priority` knob** rather than by accident. Orthogonally, _whether_ aliases are honoured is its own axis: `validate_by_alias` / `validate_by_name` / `serialize_by_alias` on the model and `by_alias=` per call — and `serialize_by_alias` defaults to `False`, so having an alias does not by itself mean you emit it.

Defaults are `default=` or `default_factory=`, and the factory may take one argument, in which case it receives the already-validated data — a default computed from sibling fields, which makes field declaration order semantically load-bearing.

The most consequential part of this section is the **tri-state**: three flags that naive designs conflate.

| Flag               | Predicate                                  | The question it answers               |
| ------------------ | ------------------------------------------ | ------------------------------------- |
| `exclude_none`     | value **is** `None`                        | "is it empty?"                        |
| `exclude_defaults` | value **equals** the declared default      | "is it interesting?"                  |
| `exclude_unset`    | the field **was not present in the input** | "did the user say anything about it?" |

Only the third is about _provenance_ rather than value, and Pydantic stores it in a side channel on the instance, `__pydantic_fields_set__` — not in the field. Two documented subtleties confirm the factoring: a post-construction assignment _adds_ the field to the set (presence means "was ever explicitly written", not "was in the wire form"), and `model_construct` bypasses population of the side channel so **only** `exclude_unset` breaks — the value-predicate flags are unaffected because they never depended on provenance. Later, `Field(exclude_if=predicate)` generalised all three: the built-in flags are three predicates over one general mechanism. Alongside them sit `Field(exclude=True)` (never emit — secrets, internal ids), `Field(repr=False)` (a _third_ output channel, distinct from both wire forms), and `Field(deprecated='use X instead')`, which both warns on access and marks the JSON Schema.

> **D verdict:** naming is [**(a)** — struct + UDA][tags] throughout — `@WireName!F("x")` with in/out variants, and `@WireName!Cli("--verbose", "-v", "--loud")` _is_ the long/short/deprecated-alias mechanism a CLI needs, one UDA, N names in and exactly one name out. Steal the explicit generated-versus-declared **precedence knob**; a D enum reads better than Pydantic's integer priority. `AliasPath` is [**(b)** — CTFE effort][tags] and worth it: it needs keyed and indexed descent, easy for a random-access wire form and hard for a purely streaming one, but for [argv][argv] it is trivial and enormously valuable — `AliasPath` _is_ `--server.port` dotted-flag support, and run backwards it is how a nested config struct presents a flat flag namespace, so `wired` should make it **bidirectional**, which Pydantic does not. The tri-state is [**(a)**][tags] for none/defaults (compile-time-generated per-field comparisons, free) and [**(c)** — value-level composition][tags] for unset, which is the decisive one: provenance needs a presence bitset, and it must **not** live inside `T`, because that breaks POD-ness, `==`, `immutable`, and hashing. Return it instead — `struct Decoded(T) { T value; FieldSet!T present; }` — zero-cost when the caller ignores it. Layered configuration (compiled defaults ← config file ← environment ← argv) is only expressible if each layer can report which fields it actually spoke about; a `Nullable!T` per field expresses it too but poisons every type and conflates absent with explicitly-null. Expose the general `@WireOmitIf!(pred)` form and define none/default/unset in terms of it.

---

## Sum types & discrimination

Pydantic's own framing:

> _"Unions are fundamentally different to all other types Pydantic validates — instead of requiring all fields/items/values to be valid, unions require only one member to be valid."_ — [Unions][docs-unions]

**Untagged unions** come in two modes. `union_mode='left_to_right'` takes the first member that validates, and is order-and-coercion sensitive in a hostile way: with `Union[int, str]` the input `'456'` becomes the _integer_ `456`, because `int` coerces first and `str` is never tried. The default, `union_mode='smart'`, scores candidates — first by number of valid fields set (for models, dataclasses and typed dicts), then by _exactness_, where an exact type match beats strict-mode success beats lax-mode success. The docs disclaim it:

> _"We reserve the right to tweak the internal smart matching algorithm in future versions of Pydantic. If you rely on very specific matching behavior, it's recommended to use `union_mode='left_to_right'` or discriminated unions."_ — [Unions][docs-unions]

**Discriminated unions** are the recommended path. A common `Literal`-typed field names the variant:

```python
class Cat(BaseModel): pet_type: Literal['cat']; meows: int
class Dog(BaseModel): pet_type: Literal['dog']; barks: float

class Model(BaseModel):
    pet: Union[Cat, Dog] = Field(discriminator='pet_type')
```

One member is attempted (fast), the choice is deterministic, and — critically — **the error names only the selected member** (`pet.dog.barks Field required`) instead of dumping every member's failure. Nested discriminators compose by stacking `Annotated`, and the generated JSON Schema implements OpenAPI's `discriminator` attribute.

**Callable discriminators** are the expressiveness jump. When the tag is not a uniform field, `Discriminator(fn)` plus per-member `Tag('…')` lets a function decide:

```python
def get_discriminator_value(v: Any) -> str | None:
    if isinstance(v, dict):
        return v.get('fruit', v.get('filling'))
    return getattr(v, 'fruit', getattr(v, 'filling', None))

class Dinner(BaseModel):
    dessert: Annotated[
        Union[Annotated[ApplePie, Tag('apple')], Annotated[PumpkinPie, Tag('pumpkin')]],
        Discriminator(get_discriminator_value),
    ]
```

The function runs in _both_ directions — it sees a `dict` during validation and an instance during serialization — and it can discriminate across non-model members (`int` versus a model), which a field-name discriminator cannot. `Discriminator(..., custom_error_type=, custom_error_message=, custom_error_context=)` then lets the union collapse a deep recursive failure into one clean message.

> **D verdict:** field discriminators are [**(a)**][tags] — `@WireTag!F("pet_type")` on a `SumType` field with each member carrying `@WireTagValue("cat")`, pure CTFE. Callable discriminators are [**(b)**][tags] **and are the whole subcommand feature**: a subcommand's tag is not a field inside the object, it is the first positional token in argv, so `git commit -m x` is a callable discriminator over `argv[0]` selecting a member of `SumType!(Commit, Push, …)` with the remaining argv decoded into it — and nested discriminators are nested subcommands (`git remote add`). Getting this right means subcommands are _not_ a special case in the parser; they are the union feature the codec already needs. The requirement it imposes on the engine is **look-ahead without commitment**, which is exactly what msgspec's [`Raw`][msgspec] provides, so design the two as one unit. Smart-mode exactness scoring is [**(c)**][tags] and mostly not worth porting: it exists because Python cannot see the input's static type and because Pydantic coerces aggressively by default. A D codec decoding into `SumType!(A, B)` from a self-describing format dispatches on the wire tag exactly, with no scoring, and where a genuinely ambiguous untagged union must be decoded, an explicit ordered try-list with coercion **off** removes the entire class of surprise. A heuristic whose own authors reserve the right to change it in a minor release is not a feature to port.

---

## Transformations & validation

Field validators come in four modes, and only the fourth is architecturally interesting.

- **before** — runs on the raw input (typed `Any`), used to _reshape_: scalar → list, string → dict.
- **after** — runs post-coercion on a statically typed value, used to _check invariants_.
- **plain** — replaces built-in validation entirely; the parse never runs.
- **wrap** — receives the rest of the pipeline as a handler.

The docs on wrap:

> _"Wrap validators: are the most flexible of all. You can run code before or after Pydantic and other validators process the input, or you can terminate validation immediately, either by returning the value early or by raising an error. Such validators must be defined with a mandatory extra handler parameter … You are free to wrap the call to the handler in a `try..except` block, or not call it at all."_ — [Validators][docs-validators]

```python
def truncate(value: Any, handler: ValidatorFunctionWrapHandler) -> str:
    try:
        return handler(value)                       # delegate downstream
    except ValidationError as err:
        if err.errors()[0]['type'] == 'string_too_long':
            return handler(value[:5])               # RETRY with a modified input
        raise

class Model(BaseModel):
    my_string: Annotated[str, Field(max_length=5), WrapValidator(truncate)]

Model(my_string='abcdef')   # my_string='abcde'
```

This is **codec middleware** in the exact sense of HTTP middleware: the hook receives `next` and decides whether to call it, when, with what, how many times, and what to do with its failure. _before_ and _after_ are each a degenerate wrap (call `next` once, at one end); _plain_ is a wrap that never calls `next`. Things only wrap can express: retry-with-fallback, catch-and-rewrite-the-error, try-an-alternate-parse-on-failure, tracing around a subtree, and supplying a default _on failure_ rather than on absence. Stacked `Annotated` validators have a defined order — _before_ and _wrap_ run right-to-left, then _after_ runs left-to-right — so the annotation list reads as an onion. The same duality exists at model level (`@model_validator(mode='wrap')`) and, symmetrically, on the encode side (`@field_serializer(mode='wrap')`, `@model_serializer(mode='wrap')`, and `PlainSerializer` as `Annotated` metadata).

Serializers add one idea validators lack: **`when_used`**, whose values are `'always'` | `'unless-none'` | `'json'` | `'json-unless-none'`. The `'json'` value encodes a real distinction between `model_dump()` (Python objects out — tuples stay tuples, `datetime` stays `datetime`) and `model_dump_json()` (JSON-legal types only): a serializer may be needed for one and not the other.

Constraints are the third leg: `gt`, `ge`, `lt`, `le`, `multiple_of`, `min_length`, `max_length`, `pattern`, `allow_inf_nan`, `max_digits`, `decimal_places`, and `strict`. Because they live in `Annotated` they attach to a _type_ and therefore nest into containers — `list[Annotated[int, Field(gt=0)]]` constrains the elements, not the list.

Coercion policy is `strict` versus lax, settable at **four** levels with inner overriding outer: per call (`model_validate(data, strict=True)`), per field (`Field(strict=True)`), per type (`Annotated[UUID, Strict()]`), and per model (`ConfigDict(strict=True)`). And it is **input-medium sensitive**: a `datetime` accepts an ISO string in strict mode when the input is JSON — where there is no other representation — but rejects a string coming from Python objects.

> **D verdict:** before/after are [**(a)**][tags]; **wrap is [(b)][tags] and is the one to build.** `__traits(getAttributes, field)` yields UDAs in declaration order, so Pydantic's onion ordering is directly available; a wrap hook is `T fn(Input, scope T delegate(Input) next)`, and composing an `AliasSeq` of them into one call graph is textbook compile-time template recursion — with `next` a `scope` delegate over a compile-time-known callee, LDC inlines the chain, so **D gets this at zero runtime cost where Python pays a stack frame and an exception round-trip per layer.** The one design constraint is that failures must be catchable and inspectable, which [`Expected!(T, E)`][expected] satisfies more cleanly than exceptions do: `handler(v).orElse(e => e.isTooLong ? handler(v[0 .. 5]) : err(e))`. **Design the hook signature as wrap-shaped from the start** and define `@WireBefore`/`@WireAfter` as sugar over it — retrofitting `next` later is a breaking change to every hook ever written against it. `when_used` is [**(a)**][tags] and generalises to a good rule: a hook should declare the conditions under which it applies rather than open with a guard clause. Constraints are [**(a)**][tags] as field UDAs and [**(b)**][tags] in the composing form, where the honest D answer — a real wrapper type `Constrained!(int, gt(0))`, usable as `Constrained!(int, gt(0))[]` — beats Pydantic's, because the constraint becomes part of the static type and survives being passed around. Do not dismiss constraints as "validation, not serialization": they are the input to `--help`, JSON Schema, and shell completion. Strict-versus-lax is [**(a)**][tags], and its medium-sensitivity is a strong external validation of `wired`'s `Format` marker — from argv _everything_ is a string, so `int` must accept `"8080"`, while from a JSON config file `"8080"` for an `int` should be an error. Port the **four-level override ladder**; all of it is compile-time in D.

---

## Errors & context

Errors are raised as `ValueError`, `AssertionError` (skipped under `-O` — a footgun that mirrors this repo's own [`-release` deletes assert expressions][buildtypes] rule), or `PydanticCustomError`, which carries a machine-readable type tag, a message template, and a context dict:

```python
raise PydanticCustomError('the_answer_error', '{number} is the answer!', {'number': v})
```

Errors accumulate a _location_: each `ValidationError.errors()` entry carries a `loc` tuple naming the path to the failing node, which is what turns a nested failure into a readable message. Discriminated unions prune this aggressively — the error names only the selected member instead of every member's failure — and `Discriminator(custom_error_type=…)` collapses a deep recursive failure into one line.

Context is the other half. `ValidationInfo` carries `.context` (arbitrary caller-supplied data), `.data` (fields validated so far), and `.field_name`:

```python
@field_validator('text', mode='after')
@classmethod
def remove_stopwords(cls, v: str, info: ValidationInfo) -> str:
    if isinstance(info.context, dict):
        stop = info.context.get('stopwords', set())
        v = ' '.join(w for w in v.split() if w.lower() not in stop)
    return v

Model.model_validate(data, context={'stopwords': ['this', 'is', 'an']})
```

Context lets the _same type_ decode differently depending on ambient information supplied at the call site — a tenant id, a schema version, a base URL for resolving relative links, a locale — without threading a mutable global or forking the type. `SerializationInfo` is the symmetric encode-side object (`.context`, `.mode`, `.field_name`, and the active `exclude_*` flags), which is what makes context-dependent _encoding_ possible: `article.model_dump(context={'redact': {'Secret'}})` redacts on the way out without a parallel loggable type.

Pydantic admits the wart: _"It is currently not possible to provide a context when directly instantiating a model"_ — you must go through `model_validate`, and the documented workaround is a `ContextVar`, i.e. a thread-local.

> **D verdict:** structured errors are [**(a)**/**(b)**][tags] — a code, a message template and a payload are exactly what `Expected!(T, WireError)` should carry; getting the **location** (`$.groups[1]`, `--server.port`) into the error is engine plumbing rather than user-facing API, and it is the difference between a usable and an unusable CLI message (`--server.port: must be > 0, got -1`). Context is [**(b)**][tags] and is one of the clearest "D wins" items in the survey: thread a `Ctx` template parameter through `decode`/`encode` and use DbI to detect which hooks want it (`static if (is(typeof(hook(value, ctx))))` — pass it, else call the one-argument form). The result is a **statically typed** context where Pydantic's is `Any` and every hook re-checks `isinstance(info.context, dict)`, zero cost when unused (`Ctx = void`), and no thread-locals. The CLI relevance is direct: terminal width, `isatty`, the environment block, the working directory for resolving relative paths, and the already-parsed global options are all context a sub-parser needs.

---

## Metadata, derivations & extensibility

The extension mechanism is uniform, and the parametrizable form reveals the architecture. A frozen dataclass used as `Annotated` metadata implements the same middleware protocol:

```python
@dataclass(frozen=True)
class MyAfterValidator:
    func: Callable[[Any], Any]

    def __get_pydantic_core_schema__(self, source_type, handler) -> CoreSchema:
        return core_schema.no_info_after_validator_function(self.func, handler(source_type))

Username = Annotated[str, MyAfterValidator(str.lower)]
```

`frozen=True` is required so the object is hashable, and therefore deduplicable and cacheable inside unions. **This is how all of `Field`, `AfterValidator`, `Strict`, and `WithJsonSchema` are implemented**: the entire public surface of Pydantic is a library of `Annotated` metadata objects over one reified schema language. `GetPydanticSchema(lambda tp, handler: …)` is the lightweight inline form, `handler.generate_schema(item_tp)` handles generic custom types, and `handler.field_name` (v2.4+) lets a type's schema depend on the name of the field it is used at.

The payoff artifact is JSON Schema, generated through a five-rung ladder in which each rung receives the previous stage's output as input:

1. `Field(title=, description=, examples=, json_schema_extra=)` — per-field metadata (stacked `json_schema_extra` dicts **merge** rather than override, since v2.9).
2. `WithJsonSchema` / `SkipJsonSchema` as `Annotated` annotations.
3. `__get_pydantic_json_schema__`, which receives the core schema and a handler, so it can _modify_ the default rather than replace it.
4. A `GenerateJsonSchema` subclass for whole-document control.
5. `ref_template='#/components/schemas/{model}'` and `models_json_schema([...])` for OpenAPI and multi-root documents.

The two modes come out correctly distinct — computed fields appear only under `mode='serialization'`, and a `Decimal` accepts number-or-string inbound while emitting string outbound — with no extra user annotation.

### Which features exist only because Python lacks static types

This split is itself a finding, and filtering it out is most of the value of studying Pydantic: roughly a third of its surface area is compensation, not expressiveness.

| Pydantic feature                         | Why it exists                                 | D equivalent                               |
| ---------------------------------------- | --------------------------------------------- | ------------------------------------------ |
| `TypeAdapter`                            | needs an object to hang a runtime schema on   | `decode!T` is already type-generic         |
| `RootModel`                              | needs a class wrapper for a bare `list[str]`  | same — no wrapper needed                   |
| `model_rebuild()` / forward references   | runtime name resolution                       | compile-time, no ceremony                  |
| `model_construct`                        | validation entangled with `__init__`          | `T(1, "Alice")` is already unvalidated     |
| Generic-model machinery, partial binding | `Generic[T]` plumbing                         | templates, natively                        |
| `validate_default`                       | defaults are untyped expressions              | initialisers are typed and CTFE-checked    |
| `strict` for _Python-object_ inputs      | "is this actually an `int`?"                  | statically known                           |
| `validate_assignment`                    | no invariants                                 | `invariant`, `const`, setters              |
| Smart-union exactness scoring            | no static input type plus aggressive coercion | dispatch on the wire tag                   |
| `frozen=True` faux immutability          | shallow — nested mutables stay mutable        | `immutable` is transitive and real         |
| `SerializeAsAny` / duck-typed dumping    | reference-semantics subclass substitution     | value structs; variants as `SumType`       |
| `create_model(...)`                      | build a model at runtime from a schema        | a CTFE string mixin covers the useful half |

The residue worth keeping from that table is a _performance_ observation: the docs warn that schema building has "non-trivial overhead", hence the advice to instantiate a `TypeAdapter` once and reuse it. D builds the schema at compile time, so that entire category of advice evaporates.

> **D verdict:** the metadata protocol is [**(b)**][tags], and all five JSON-Schema rungs are CTFE-expressible. The transferable lesson is the ladder's _shape_ — **a good default, then escalating override points, each receiving the previous stage's output as input** — which is the same middleware idea applied uniformly, and is why a library this large still feels coherent. Two concrete constraints transfer. First, `frozen=True`: metadata payloads must be value-comparable and hashable so the engine can deduplicate and cache them, so in D, UDA payloads should be plain comparable structs, never classes or delegates-with-state. Second, the `Annotated` channel is open — which is why `wired` must **ignore UDAs it does not recognise and never error on them** [**(a)**][tags]. The moment `wired` rejects unknown attributes, a struct can no longer carry an ORM's column annotation or a project's own metadata alongside `@WireName`, and the entire value of this declaration model is that multiple consumers read the same declaration. Cheap up front, expensive to retrofit. Everything in the compensation table above falls outside the tag scale entirely — it is not expressiveness to port at any effort level, it is scaffolding D does not need.

---

## Strengths

- **The most expressive vocabulary surveyed.** Aliases in three directions plus choices plus paths, four validator modes in both directions, four-level strictness, discriminated unions with callable discriminators, computed fields, three-way unknown-field policy, and a provenance side channel.
- **One reified artifact, many derivations.** Validator, serializer, and two distinct JSON Schema modes all fall out of the same `CoreSchema`, so they cannot drift apart.
- **Uniform middleware shape.** Field validators, model validators, serializers, and schema generation all take a handler, so learning one teaches the rest.
- **`Annotated` metadata composes and nests.** A constraint attaches to a _type_, so `list[PositiveInt]` constrains elements without a container-aware special case.
- **Provenance is factored correctly** — value predicates on the value, presence in a side channel — and the design proves itself when `model_construct` breaks only `exclude_unset`.
- **Ubiquity.** FastAPI-scale adoption means the sharp edges are documented rather than discovered.

## Weaknesses

- **Surface area.** Roughly a third is Python-type compensation, and the remainder still overlaps heavily: positional `Field()` versus `Annotated`, decorator versus annotated validators, `Field(exclude_if=)` versus three older flags.
- **Smart-union scoring is a heuristic the maintainers disclaim**, changeable in a minor release.
- **Context cannot be supplied to a direct constructor**; the documented workaround is a `ContextVar` thread-local.
- **Runtime cost is structural.** Schema building has "non-trivial overhead" that must be amortised by caching adapters, and every hook is a Python call frame.
- **`AliasPath` is decode-only** — the most valuable shape-decoupling feature does not run backwards.
- **Assertion-based validators vanish under `-O`**, the same class of hazard as `-release` deleting D assert _expressions_.
- **Ordering rules are subtle**: stacked `Annotated` validators run before/wrap right-to-left and after left-to-right, and a data-taking `default_factory` makes field declaration order semantic.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                        | Trade-off                                                                                       |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Reify the codec as a `CoreSchema` value interpreted by Rust    | One description drives validator, serializer, and both JSON Schema modes         | The schema must be built and cached at runtime; "instantiate `TypeAdapter` once" becomes advice |
| Policy on the type, via `Annotated` metadata                   | One place to read the contract; static type checkers still see the plain type    | Cannot annotate a type you do not own; one type in two contexts needs two models                |
| Every hook takes a `handler` (`next`)                          | Retry, fallback, error rewriting and instrumentation all become expressible      | An extra parameter and a delegation discipline in every hook; ordering rules to memorise        |
| Three alias axes plus `AliasChoices` plus `AliasPath`          | Decode names, encode names and wire _shape_ are genuinely independent            | A large naming surface, and `AliasPath` runs in one direction only                              |
| Provenance in a side channel, not in the field                 | The value stays a value; `exclude_unset` answers a question the value cannot     | Construction paths that skip the side channel silently break `exclude_unset`                    |
| Lax coercion by default, strictness overridable at four levels | Wire formats differ in what they can represent; argv-like inputs are all strings | Surprising coercions by default, which then motivates the smart-union scoring                   |
| Smart union scoring as the default union mode                  | Beats left-to-right's coercion-order accidents for typical inputs                | Heuristic, explicitly unstable across minor versions; production advice is to avoid it          |
| `computed_field` — encode-only members                         | The encode field set genuinely differs from the decode field set                 | Two schemas to generate and reason about; asymmetry throughout the engine                       |
| `extra='allow'` preserving unknowns in `__pydantic_extra__`    | Partial models act as lossless proxies over documents they only partly know      | Untyped by default, so fidelity depends on the mapping type chosen                              |

---

## Sources

- [pydantic/pydantic — GitHub repository][repo] · [pydantic/pydantic-core (the Rust engine)][core-repo]
- [Pydantic documentation — validation concepts][docs]
- [Fields — `Field()`, aliases, defaults, constraints][docs-fields]
- [Validators — before / after / plain / wrap, `ValidationInfo`][docs-validators]
- [Serialization — serializers, `computed_field`, the `exclude_*` family][docs-serialization]
- [Unions — smart mode, left-to-right, discriminators, `Tag`][docs-unions]
- [Custom types — `__get_pydantic_core_schema__`, the middleware protocol][docs-types]
- [JSON Schema — the customisation ladder, validation versus serialization modes][docs-jsonschema]
- [Strict mode — the four override levels and medium sensitivity][docs-strict]
- [Models — `model_config`, `extra`, `model_construct`][docs-models]
- Catalog siblings: [serde overview][index] · [concepts][concepts] · [msgspec & cattrs][msgspec] · [`serde` (Rust)][serde] · [`facet` (Rust)][facet] · [Effect Schema][effect] · [ZIO Schema][zio] · [circe & aeson][circe] · [Haskell codecs][haskell] · [invertible syntax][invertible] · [OCaml ATD][atd] · [argv codecs][argv] · [`wired` baseline][baseline] · [comparison][comparison]

<!-- References -->

[repo]: https://github.com/pydantic/pydantic
[core-repo]: https://github.com/pydantic/pydantic-core
[docs]: https://pydantic.dev/docs/validation/latest/
[docs-fields]: https://pydantic.dev/docs/validation/latest/concepts/fields/
[docs-validators]: https://pydantic.dev/docs/validation/latest/concepts/validators/
[docs-serialization]: https://pydantic.dev/docs/validation/latest/concepts/serialization/
[docs-unions]: https://pydantic.dev/docs/validation/latest/concepts/unions/
[docs-types]: https://pydantic.dev/docs/validation/latest/concepts/types/
[docs-jsonschema]: https://pydantic.dev/docs/validation/latest/concepts/json_schema/
[docs-strict]: https://pydantic.dev/docs/validation/latest/concepts/strict_mode/
[docs-models]: https://pydantic.dev/docs/validation/latest/concepts/models/
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[concepts]: ./concepts.md
[index]: ./index.md
[comparison]: ./comparison.md
[baseline]: ./wired-baseline.md
[msgspec]: ./msgspec-cattrs.md
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
[buildtypes]: ../../guidelines/AGENTS.md#build-types-debug-to-test-checked-to-ship-never-release
