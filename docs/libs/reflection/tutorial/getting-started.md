# Getting started

Add the package as a dependency — it has none of its own:

```sdl
dependency "sparkles:reflection" path="../.."
```

## Classify a type

```d
import sparkles.reflection.kind : TypeKind, typeKindOf;

static assert(typeKindOf!int == TypeKind.signedInteger);
static assert(typeKindOf!string == TypeKind.text);
static assert(typeKindOf!(int[]) == TypeKind.sequence);
```

`typeKindOf` is the one total ladder every consumer shares: enums before
integrals, strings before arrays, `SumType` before aggregates. The scalar
kinds (`isScalarKind`) are exactly the leaves a value writer or query sink
can consume directly.

## Discover members

```d
import sparkles.reflection.member : fieldCount, fieldIdentifier,
    propertyGetters, valueLikeGetter;

static assert(fieldCount!MyStruct == 2);
static assert(fieldIdentifier!(MyStruct, 0) == "alpha");
```

The field primitives are indexed into `T.tupleof` — the same spine a
runtime walk reads — so a field's compile-time symbol, type, and identifier
always agree with the value a consumer hands out. `propertyGetters!T` lists
the public zero-argument `@property` getters (one per member name, setters
and private overloads excluded), and `valueLikeGetter!T` states the
value-like wrapper rule: a fieldless type whose single public `@property`
returns a scalar _is_ that value.

## Build your own walk

The kernel deliberately ships no visitor: each consumer's traversal has its
own shape (the property tree prunes by disclosure at runtime; a query
schema enumerates every `SumType` alternative at compile time; a writer
never recurses at all). A direct `static if` ladder over `typeKindOf`,
recursing through `fieldCount`/`fieldType` and `propertyGetters`, stays
close to the consumer's policy and instantiates nothing it does not use —
`sparkles.dql.schema` and `sparkles.dql.resolve` are the reference pair,
two mirrored ladders over one conventions module.
