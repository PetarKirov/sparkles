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

## Walk a type

```d
import sparkles.reflection.visit : visitType;

struct Collector
{
    string[] scalars;

    void leaf(T)() { scalars ~= T.stringof; }
    void enterField(T, size_t i)() { /* before field i's type */ }
}

Collector c;
visitType!MyStruct(c);
```

Every hook is optional. A visitor that defines nothing still walks — the
`void`-visitor baseline — and hooks are probed with the exact instantiation
they will be called with.

## Walk a value

```d
import sparkles.reflection.visit : visitValue;

struct Counter
{
    long scalars;
    void scalar(T)(ref T) { scalars++; }
}

MyStruct value;
Counter counter;
assert(visitValue(value, counter));
```

`visitValue` hands fields, elements, and active `SumType` alternatives to the
visitor by reference, reports null pointers and null associative arrays
through an optional `absent` hook, and returns `false` when a hook requested
`ValueControl.stop`.

## Reduce fields to a table

```d
import sparkles.reflection.member : fieldTable, fieldIdentifier;

template fieldName(size_t i)
{
    enum string fieldName = fieldIdentifier!(MyStruct, i);
}

alias names = fieldTable!(MyStruct, fieldName);
```

`fieldTable` is the one-pass CTFE spine serialization policies and schema
generators reduce into: one entry per declared field, nested context pointers
excluded, built once so per-index reads do not re-materialize the table.
