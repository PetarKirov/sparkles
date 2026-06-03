# Expected Error Handling Idioms

This guide provides idiomatic patterns for error handling in D using the [`github:tchaloupka/expected`][expected] library (a core dependency in this codebase), with side-by-side comparisons for developers coming from Rust.

## Motivation

In standard `@safe pure nothrow @nogc` D code, throwing garbage-collected exceptions is disallowed. The [`github:tchaloupka/expected`][expected] library provides an algebraic data type `Expected!(T, E)` that represents either a successful result `T` (via `ok`) or a structured failure `E` (via `err`), with zero heap allocations.

---

## 1. Flattening Collections (`flatten`)

**Problem:** You have a collection of fallible results, and you want to filter out all errors while extracting and unwrapping all successful values.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "flatten_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
import std.algorithm : joiner;
import expected : ok, err;

void main()
{
    auto items = [
        ok!(string)(1),
        err!int("error"),
        ok!(string)(3),
        err!int("bad"),
        ok!(string)(5)
    ];

    writeln("Successes: ", items.joiner);
    writeln("Items: ", items);
}
```

```[Output]
Successes: [1, 3, 5]
Items: [[1], [], [3], [], [5]]
```

```rust [Rust]
let items = vec![Ok(1), Err("error"), Ok(3), Err("bad"), Ok(5)];

// Flatten filters out Errs and unwraps Oks
let successes: Vec<i32> = items.into_iter().flatten().collect();
assert_eq!(successes, vec![1, 3, 5]);
```

:::

> [!NOTE]
> Since `Expected!(T, E)` exposes the standard D Range primitives `empty`, `front`, and `popFront` (where a failure is empty and a success yields `1` element), Phobos algorithms like `joiner` flat-map it natively without any custom conversion.

---

## 2. Chaining Fallible Operations (`and_then`)

**Problem:** You want to perform multiple consecutive operations where each operation depends on the success of the previous one, and any step might fail.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "and_then_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
import expected : Expected, ok, err, andThen;

Expected!(int, string) parse(string s)
{
    try
    {
        import std.conv : to;
        return ok!(string)(s.to!int);
    }
    catch (Exception)
    {
        return err!int("invalid integer");
    }
}

Expected!(int, string) validate(int i)
{
    if (i < 0)
        return err!int("negative value");
    return ok!(string)(i);
}

void main()
{
    // Use `andThen` to chain fallible steps. Subsequent steps are bypassed on failure.
    auto val1 = parse("42").andThen!validate;
    writeln("42: ", val1.hasValue ? "Success" : "Error");

    auto val2 = parse("-10").andThen!validate;
    writeln("-10: ", val2.hasError ? val2.error : "Success");
}
```

```[Output]
42: Success
-10: negative value
```

```rust [Rust]
fn parse(s: &str) -> Result<i32, &str> { ... }
fn validate(i: i32) -> Result<i32, &str> { ... }

let val = parse("42").and_then(validate);
```

:::

---

## 3. Mapping Value and Error Payloads (`map` / `map_err`)

**Problem:** You want to transform the successful value or translate the error payload of a result without checking it manually.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "map_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
import std.format : format;
import expected : ok, map, mapError;

void main()
{
    auto result = ok!(string)(21);

    // Use camelCase `map` and `mapError` to transform payloads.
    auto mapped = result
        .map!(x => x * 2)
        .mapError!(e => format("Fatal: %s", e));

    writeln("Mapped: ", mapped.value);
}
```

```[Output]
Mapped: 42
```

```rust [Rust]
let result: Result<i32, &str> = Ok(21);

let mapped = result
    .map(|x| x * 2)
    .map_err(|e| format!("Fatal: {}", e));
```

:::

---

## 4. Default Fallbacks (`unwrap_or` / `unwrap_or_else`)

**Problem:** You want to unwrap the success value, or fall back to a default value (either eager or lazily computed) if it is a failure.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "fallback_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
import expected : Expected, err, orElse;

int computeDefault()
{
    return 100;
}

void main()
{
    Expected!(int, string) result = err!int("oops");

    // In D, `orElse` is overloaded to accept either a value or a lazy compile-time delegate.

    // Eager fallback
    writeln("Eager: ", result.orElse(100));

    // Lazy fallback via a compile-time delegate
    writeln("Lazy: ", result.orElse!(() => computeDefault()));
}
```

```[Output]
Eager: 100
Lazy: 100
```

```rust [Rust]
// Eager fallback
let val = result.unwrap_or(100);

// Lazy fallback via closure
let lazy_val = result.unwrap_or_else(|| compute_default());
```

:::

---

## 5. Collapsing Paths into a Single Value (`map_or_else` / `match`)

**Problem:** You want to consume both the success and failure branches, mapping them to a single type using handlers for each path.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "collapse_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
import std.format : format;
import expected : ok, mapOrElse;

void main()
{
    auto result = ok!(string)(21);

    // In D, `mapOrElse` takes two lambdas: (success_payload, error_payload)
    auto message = result.mapOrElse!(
        v => format("Success: %s", v),
        e => format("Error occurred: %s", e)
    );

    writeln(message);
}
```

```[Output]
Success: 21
```

```rust [Rust]
let message = result.map_or_else(
    |e| format!("Error occurred: {}", e),
    |v| format!("Success: {}", v),
);
```

:::

---

## Cheat Sheet: Rust `Result` vs D `Expected`

| Operation          | Rust `Result<T, E>`       | D `Expected!(T, E)`                    |
| :----------------- | :------------------------ | :------------------------------------- |
| Creation (Success) | `Ok(value)`               | `ok(value)` or `ok!(ErrorType)(value)` |
| Creation (Failure) | `Err(error)`              | `err!ValType(error)`                   |
| Check Success      | `res.is_ok()`             | `res.hasValue` (or cast to `bool`)     |
| Check Failure      | `res.is_err()`            | `res.hasError`                         |
| Unsafe Unwrap      | `res.unwrap()`            | `res.value` (asserts or throws)        |
| Retrieve Error     | `res.unwrap_err()`        | `res.error`                            |
| Monadic Chaining   | `res.and_then(f)`         | `res.andThen!f` or `res.andThen(f)`    |
| Monadic Fallback   | `res.or_else(f)`          | `res.orElse!f` or `res.orElse(f)`      |
| Map Success        | `res.map(f)`              | `res.map!f`                            |
| Map Failure        | `res.map_err(f)`          | `res.mapError!f`                       |
| Double Map / Match | `res.map_or_else(fe, fv)` | `res.mapOrElse!(fv, fe)`               |
| Flatten Collection | `iter.flatten()`          | `range.joiner`                         |

[expected]: https://github.com/tchaloupka/expected
