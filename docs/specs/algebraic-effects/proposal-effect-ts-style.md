# Proposal B: Effect-TS Style Algebraic Effect System

## Status

Draft v0.1 (Proposal B)

## Goal

Design a purely functional, monadic, builder-pattern algebraic effect system for D. This approach is heavily inspired by Effect TS and Scala ZIO. It encodes effects in the return type of the function and uses a builder method where each method in the chain modifies the return type.

The goal is to provide exactly the type-safe, fluent builder pattern you see in Effect TS, entirely verified at compile time in D.

## Design Principles

1.  **Total Type Safety:** The compiler statically guarantees that you cannot run the program until every requirement is provided and all errors are either handled or explicitly bubbled up.
2.  **Referential Transparency:** Functions do not _do_ things; they return immutable descriptions of things to do.
3.  **Ergonomics via Type Inference:** Leverage D's native `noreturn` (bottom type) and `std.sumtype` to represent the absence of errors/requirements and type-level unions, respectively, minimizing boilerplate and manual type-list construction.

## The Core Data Type

The system revolves around a single parameterized struct:

```d
struct Effect(T, Errors, Requirements)
{
    // Opaque internal execution state
}
```

- **`T` (Value):** The success value.
- **`Errors` (Errors):** The potential failures. We use `SumType` for multiple errors. If it cannot fail, it is `noreturn`.
- **`Requirements` (Environment):** The environment required to run. We use type unions/intersections. If no requirements are needed, it is `noreturn`.

## Simulating TypeScript Unions

To mimic TypeScript's `A | B` union types, we define templates that merge type lists, remove duplicates, and filter out `noreturn`.

```d
import std.sumtype;
import std.meta : NoDuplicates, Filter, AliasSeq, staticMap;

enum isNotNoReturn(T) = !is(T == noreturn);

template Extract(T)
{
    static if (is(T == noreturn))
        alias Extract = AliasSeq!();
    else static if (is(T : SumType!Args, Args...))
        alias Extract = Args;
    else
        alias Extract = AliasSeq!T;
}

template Union(Types...)
{
    alias Flat = staticMap!(Extract, Types);
    alias Valid = Filter!(isNotNoReturn, Flat);
    alias Unique = NoDuplicates!Valid;

    static if (Unique.length == 0)
        alias Union = noreturn;
    else static if (Unique.length == 1)
        alias Union = Unique[0];
    else
        alias Union = SumType!Unique;
}

template Remove(Target, T)
{
    enum isNotTarget(U) = !is(U == Target);

    alias Flat = Extract!T;
    alias Remaining = Filter!(isNotTarget, Flat);

    alias Remove = Union!Remaining;
}
```

## Builder Primitives

Using `noreturn` explicitly communicates guarantees to the compiler:

```d
// Succeeds with value `v`. Never fails. Needs nothing.
Effect!(T, noreturn, noreturn) succeed(T)(T v) { /* ... */ }

// Fails with error `e`. Never succeeds. Needs nothing.
Effect!(noreturn, E, noreturn) fail(E)(E e) { /* ... */ }

// Asks for requirement `R`. Never fails. Returns `R`.
Effect!(R, noreturn, R) ask(R)() { /* ... */ }
```

Because D's `noreturn` implicitly converts to any type, returning it allows these effects to merge flawlessly into pipelines.

## The Fluent Chaining API (UFCS)

Operations calculate their new type signature at compile time.

```d
// flatMap: Chains operations, merging Errors and Requirements
auto flatMap(alias fn, T, E, R)(Effect!(T, E, R) eff)
{
    alias NextEff = typeof(fn(T.init));

    alias NewT = NextEff.ValueType;
    alias NewE = Union!(E, NextEff.ErrorType);
    alias NewR = Union!(R, NextEff.RequireType);

    return Effect!(NewT, NewE, NewR).init;
}

// catchAll: Handles errors, replacing them in the type signature
auto catchAll(alias fn, T, E, R)(Effect!(T, E, R) eff)
if (!is(E == noreturn)) // Can only catch if it actually fails
{
    alias HandlerResult = typeof(fn(E.init));

    alias NewT = Union!(T, HandlerResult.ValueType);
    alias NewE = HandlerResult.ErrorType; // Errors reset to handler's errors
    alias NewR = Union!(R, HandlerResult.RequireType);

    return Effect!(NewT, NewE, NewR).init;
}

// provide: Injects dependencies, removing them from Requirements
auto provide(ProvidedR, T, E, R)(Effect!(T, E, R) eff, ProvidedR service)
{
    alias NewR = Remove!(ProvidedR, R);
    return Effect!(T, E, NewR).init;
}

// runSync: The execution boundary. Fails to compile if requirements remain.
T runSync(T, E)(Effect!(T, E, noreturn) eff)
{
    // Execution logic
    return T.init;
}
```

## Example Usage

The resulting code behaves exactly like TypeScript Effect but relies entirely on D's native type system.

```d
struct Config { string dbUrl; }
struct DbConnection { /* ... */ }
struct DbError { string msg; }
struct NetworkError { string msg; }

auto fetchUser(int id)
{
    return ask!(Config)()
        .flatMap!(cfg => ask!(DbConnection)())
        .flatMap!(db => /* ... fetch logic ... */ fail(DbError("timeout")))
        .flatMap!(row => /* ... parse logic ... */ fail(NetworkError("bad format")));
}

void main()
{
    auto program = fetchUser(42)
        // 1. Handle all errors safely using exhaustive matching
        .catchAll!(err => err.match!(
            (DbError e)      => succeed(User.defaultUser),
            (NetworkError e) => succeed(User.defaultUser)
        ))
        // 2. Provide dependencies
        .provide(Config("postgres://localhost"))
        .provide(DbConnection());

    // 3. Execute
    User u = runSync(program); // Compiles perfectly.
}
```

## Why this specific encoding is powerful:

1. **`noreturn` as Identity:** It perfectly represents TS `never` and integrates flawlessly without type conflicts.
2. **`std.sumtype` Exhaustiveness:** The user can use D's native `match!`, enforcing compile-time exhaustiveness checks for error handling.
3. **No Variadic Generics Boilerplate:** Multiple errors collapse into a single `SumType`, meaning the `Effect` struct only ever has exactly 3 type parameters, preventing "angle-bracket blindness".
