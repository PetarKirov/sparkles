# Expected Error Handling Idioms

This guide provides idiomatic patterns for error handling in D using the [`github:tchaloupka/expected`][expected-repo] library (a core dependency in this codebase), with side-by-side comparisons for developers coming from Rust.

## Motivation

In standard `@safe pure nothrow @nogc` D code, throwing garbage-collected exceptions is disallowed. The [`github:tchaloupka/expected`][expected-repo] library provides an algebraic data type [`Expected!(T, Error, Hook)`][Expected] that represents either a successful result `T` (via [`ok`][ok]) or a structured failure `Error` (via [`err`][err]), with zero heap allocations.

### Design by Introspection (Hooks)

The `Hook` template parameter defines the execution policies of [`Expected`][Expected] (such as assertion checking or exception throwing on illegal access). It defaults to [`Abort`][Abort]. Subsystems can use D's Design by Introspection (DbI) to customize these policies or define custom hooks to completely disable default-construction in `@nogc` code (see [section 7](#_7-designing-nogc-apis-custom-hooks-aliases-helpers)).

---

## 1. Basic Usage (Success & Failure Construction)

**Problem:** You want to return a value or a structured error from a function without allocating memory on the heap (using standard exceptions) and keeping the function `@safe pure nothrow @nogc`.

**Solution:** Use [`Expected!(T, E)`][Expected] to represent the outcome. Return [`ok(value)`][ok] on success or [`err!T(error)`][err] on failure.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "basic_usage_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
// [!code focus:31]
import expected : Expected, ok, err;

enum Verbosity
{
    quiet,
    normal,
    verbose
}

@safe pure nothrow @nogc
Expected!(Verbosity, string) parseVerbosity(string level)
{
    switch (level)
    {
        case "q", "quiet":   return ok(Verbosity.quiet);
        case "n", "normal":  return ok(Verbosity.normal);
        case "v", "verbose": return ok(Verbosity.verbose);
        default:             return err!Verbosity("Unknown verbosity level");
    }
}

void main()
{
    auto result1 = parseVerbosity("quiet");
    if (result1.hasValue)
        writeln("Success: ", result1.value);

    auto result2 = parseVerbosity("invalid");
    if (result2.hasError)
        writeln("Error: ", result2.error);
}
```

```[Output]
Success: quiet
Error: Unknown verbosity level
```

```rust [Rust]
// Rust equivalent using standard Result enum
#[derive(Debug)]
pub enum Verbosity {
    Quiet,
    Normal,
    Verbose,
}

pub fn parse_verbosity(level: &str) -> Result<Verbosity, &'static str> {
    match level {
        "q" | "quiet" => Ok(Verbosity.Quiet),
        "n" | "normal" => Ok(Verbosity.Normal),
        "v" | "verbose" => Ok(Verbosity.Verbose),
        _ => Err("Unknown verbosity level"),
    }
}
```

:::

---

## 2. Flattening Collections (`flatten`)

**Problem:** You have a collection of fallible results, and you want to filter out all errors while extracting and unwrapping all successful values.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "flatten_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
// [!code focus:16]
import std.algorithm : joiner;
import expected : ok, err;

void main()
{
    auto items = [
        ok(1),
        err!int("error"),
        ok(3),
        err!int("bad"),
        ok(5)
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
> Since [`Expected!(T, E)`][Expected] exposes the standard D Range primitives `empty`, `front`, and `popFront` (where a failure is empty and a success yields `1` element), Phobos algorithms like `joiner` flat-map it natively without any custom conversion.

---

## 3. Chaining Fallible Operations (`and_then`)

**Problem:** You want to perform multiple consecutive operations where each operation depends on the success of the previous one, and any step might fail.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "and_then_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
// [!code focus:33]
import expected : Expected, ok, err, andThen;

void main()
{
    // Use `andThen` to chain fallible steps. Subsequent steps are bypassed on failure.
    auto val1 = parseAge("42").andThen!validate;
    writeln("42: ", val1.hasValue ? "Success" : "Error");

    auto val2 = parseAge("invalid").andThen!validate;
    writeln("invalid: ", val2.hasError ? val2.error : "Success");
}

@safe pure nothrow
Expected!(int, string) parseAge(string s)
{
    try
    {
        import std.conv : to;
        return ok(s.to!int);
    }
    catch (Exception e)
    {
        return err!int("Invalid age: " ~ e.msg);
    }
}

@safe pure nothrow @nogc
Expected!(int, string) validate(int i)
{
    if (i < 0)
        return err!int("negative value");
    return ok(i);
}
```

```[Output]
42: Success
invalid: Invalid age: Unexpected 'i' when converting from type string to type int
```

```rust [Rust]
fn parse_age(s: &str) -> Result<i32, String> {
    s.parse::<i32>().map_err(|e| format!("Invalid age: {}", e))
}

fn validate(i: i32) -> Result<i32, String> {
    if i < 0 {
        Err("negative value".to_string())
    } else {
        Ok(i)
    }
}

let val = parse_age("42").and_then(validate);
```

:::

> [!TIP]
> This pattern allows you to **bridge throwing code into `nothrow` functions**. By catching standard `Exception`s, wrapping the exception message (`e.msg`) with additional context, and returning an [`Expected`][Expected] object, you satisfy the compiler's `nothrow` guarantees while preserving diagnostic data.

---

## 4. Mapping Value and Error Payloads (`map` / `map_err`)

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
// [!code focus:12]
import expected : ok, map, mapError;

void main()
{
    auto result = ok(21);

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

## 5. Default Fallbacks (`unwrap_or` / `unwrap_or_else` / `or_else`)

**Problem:** You want to unwrap the success value (falling back to an eager or lazily computed default value), or chain a fallback `Expected` result on failure.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "fallback_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
// [!code focus:32]
import expected : Expected, err, ok, orElse;

int computeDefault()
{
    return 100;
}

void main()
{
    Expected!(int, string) result = err!int("oops");

    // In D, `orElse` is a unified operator. Depending on the arguments,
    // it automatically behaves like Rust's `unwrap_or`, `unwrap_or_else`, or `or_else`:

    // 1. Acts like `unwrap_or` (returns unwrapped `T` value eagerly)
    writeln("Eager Value: ", result.orElse(100)); // [!code highlight]

    // 2. Acts like `unwrap_or_else` (returns unwrapped `T` value lazily using D's `lazy` params)
    // Note: computeDefault() is ONLY called if result is a failure!
    writeln("Lazy Expression: ", result.orElse(computeDefault())); // [!code highlight]

    // 3. Acts like `unwrap_or_else` (returns unwrapped `T` value via explicit delegate)
    writeln("Lazy Delegate: ", result.orElse!(() => computeDefault())); // [!code highlight]

    // 4. Acts like `or_else` (returns a wrapped `Expected` result via explicit delegate)
    auto wrapped = result.orElse!(() => ok(200)); // [!code highlight]
    writeln("Wrapped: ", wrapped.value);

    // 5. Acts like `or_else` with error inspection (returns wrapped `Expected` result)
    auto wrappedErr = result.orElse!((err) => ok(cast(int) err.length * 100)); // [!code highlight]
    writeln("Wrapped with Err: ", wrappedErr.value);
}
```

```[Output]
Eager Value: 100
Lazy Expression: 100
Lazy Delegate: 100
Wrapped: 200
Wrapped with Err: 400
```

```rust [Rust]
// Eager fallback (returns T)
let val = result.unwrap_or(100); // [!code highlight]

// Lazy fallback via closure (returns T)
let lazy_val = result.unwrap_or_else(|| compute_default()); // [!code highlight]

// Chain fallback result (returns Result<T, F>)
let wrapped = result.or_else(|_err| Ok(200)); // [!code highlight]

// Chain fallback using error payload (returns Result<T, F>)
let wrapped_err = result.or_else(|err| Ok(err.len() * 100)); // [!code highlight]
```

:::

---

## 6. Collapsing Paths into a Single Value (`map_or_else` / `match`)

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
// [!code focus:14]
import expected : ok, mapOrElse;

void main()
{
    auto result = ok(21);

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

## 7. Designing `@nogc` APIs (Custom Hooks, Aliases & Helpers)

**Problem:** In `@nogc nothrow` APIs (such as text parsers), you want to guarantee that [`Expected`][Expected] instances are never silently default-constructed into ambiguous states (which defaults to success with `T.init`). You also want to reduce construction boilerplate for your specific error payload types.

**Solution:**

1. Use a **custom hook** containing `enableDefaultConstructor = false` to disable the default constructor of [`Expected`][Expected] at compile time (triggering `@disable this()`).
2. Define a **subsystem-wide template alias** to lock in the error type and custom hook.
3. Provide **domain-specific helper functions** (e.g. `parseOk` / `parseErr`) that implicitly forward these parameters to clean up syntax.

::: code-group

```d [D]
#!/usr/bin/env dub
/+ dub.sdl:
    name "nogc_api_example"
    dependency "expected" version="~>0.4.0"
+/
import std.stdio : writeln;
// [!code focus:40]
import expected : Expected, ok, err;

enum ParseErrorCode
{
    unexpectedCharacter,
    numericOverflow
}

struct ParseError
{
    ParseErrorCode code;
    size_t offset;
}

// 1. Custom hook to disable default construction in @nogc code
struct NoGcHook
{
    static immutable bool enableDefaultConstructor = false;
}

// 2. Subsystem template alias locking in ParseError and NoGcHook
alias ParseExpected(T) = Expected!(T, ParseError, NoGcHook);

// 3. API constructor helpers to reduce generic boilerplate
ParseExpected!T parseOk(T)(T value) @safe pure nothrow @nogc
    => ok!(ParseError, NoGcHook)(value);

ParseExpected!T parseErr(T)(ParseErrorCode code, size_t offset) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(ParseError(code, offset));

void main()
{
    // ParseExpected!int uninit; // Compile error: default constructor is @disabled!

    auto success = parseOk(42);
    auto failure = parseErr!int(ParseErrorCode.numericOverflow, 5);

    writeln("Value: ", success.value);
    writeln("Error offset: ", failure.error.offset);
}
```

```[Output]
Value: 42
Error offset: 5
```

```rust [Rust]
// In Rust, there is no default constructor for Result, and type aliases are used similarly.
#[derive(Debug)]
pub enum ParseErrorCode {
    UnexpectedCharacter,
    NumericOverflow,
}

#[derive(Debug)]
pub struct ParseError {
    pub code: ParseErrorCode,
    pub offset: usize,
}

// 1. Subsystem type alias
pub type ParseResult<T> = Result<T, ParseError>;

// Helper constructors
pub fn parse_ok<T>(val: T) -> ParseResult<T> { Ok(val) }
pub fn parse_err<T>(code: ParseErrorCode, offset: usize) -> ParseResult<T> {
    Err(ParseError { code, offset })
}
```

:::

---

## Cheat Sheet: D `Expected` vs Rust `Result`

| Operation                                                                        | D `Expected!(T, E)`                                                                                         | Rust `Result<T, E>`                                                                                    |
| :------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------- |
| [Creation (Success)](#_1-basic-usage-success-failure-construction)               | [`ok(value)`](https://tchaloupka.github.io/expected/expected.ok.html) or `ok!(ErrorType)(value)`            | [`Ok(value)`](https://doc.rust-lang.org/std/result/enum.Result.html#variant.Ok)                        |
| [Creation (Failure)](#_1-basic-usage-success-failure-construction)               | [`err!ValType(error)`](https://tchaloupka.github.io/expected/expected.err.html)                             | [`Err(error)`](https://doc.rust-lang.org/std/result/enum.Result.html#variant.Err)                      |
| [Check Success](#_1-basic-usage-success-failure-construction)                    | [`res.hasValue`](https://tchaloupka.github.io/expected/expected.Expected.hasValue.html) (or cast to `bool`) | [`res.is_ok()`](https://doc.rust-lang.org/std/result/enum.Result.html#method.is_ok)                    |
| [Check Failure](#_1-basic-usage-success-failure-construction)                    | [`res.hasError`](https://tchaloupka.github.io/expected/expected.Expected.hasError.html)                     | [`res.is_err()`](https://doc.rust-lang.org/std/result/enum.Result.html#method.is_err)                  |
| [Unsafe Unwrap](#_1-basic-usage-success-failure-construction)                    | [`res.value`](https://tchaloupka.github.io/expected/expected.Expected.value.html) (asserts/throws)          | [`res.unwrap()`](https://doc.rust-lang.org/std/result/enum.Result.html#method.unwrap)                  |
| [Retrieve Error](#_1-basic-usage-success-failure-construction)                   | [`res.error`](https://tchaloupka.github.io/expected/expected.Expected.error.html)                           | [`res.unwrap_err()`](https://doc.rust-lang.org/std/result/enum.Result.html#method.unwrap_err)          |
| [Monadic Chaining](#_3-chaining-fallible-operations-and-then)                    | [`res.andThen!f`](https://tchaloupka.github.io/expected/expected.andThen.1.html) or `res.andThen(f)`        | [`res.and_then(f)`](https://doc.rust-lang.org/std/result/enum.Result.html#method.and_then)             |
| [Eager Fallback Value](#_5-default-fallbacks-unwrap-or-unwrap-or-else-or-else)   | [`res.orElse(value)`](https://tchaloupka.github.io/expected/expected.orElse.1.html)                         | [`res.unwrap_or(value)`](https://doc.rust-lang.org/std/result/enum.Result.html#method.unwrap_or)       |
| [Lazy Fallback Value](#_5-default-fallbacks-unwrap-or-unwrap-or-else-or-else)    | [`res.orElse(expr)`](https://tchaloupka.github.io/expected/expected.orElse.1.html) or `res.orElse!f`        | [`res.unwrap_or_else(f)`](https://doc.rust-lang.org/std/result/enum.Result.html#method.unwrap_or_else) |
| [Monadic Fallback](#_5-default-fallbacks-unwrap-or-unwrap-or-else-or-else)       | [`res.orElse!f`](https://tchaloupka.github.io/expected/expected.orElse.1.html) (returning `Expected`)       | [`res.or_else(f)`](https://doc.rust-lang.org/std/result/enum.Result.html#method.or_else)               |
| [Map Success](#_4-mapping-value-and-error-payloads-map-map-err)                  | [`res.map!f`](https://tchaloupka.github.io/expected/expected.map.html)                                      | [`res.map(f)`](https://doc.rust-lang.org/std/result/enum.Result.html#method.map)                       |
| [Map Failure](#_4-mapping-value-and-error-payloads-map-map-err)                  | [`res.mapError!f`](https://tchaloupka.github.io/expected/expected.mapError.html)                            | [`res.map_err(f)`](https://doc.rust-lang.org/std/result/enum.Result.html#method.map_err)               |
| [Double Map / Match](#_6-collapsing-paths-into-a-single-value-map-or-else-match) | [`res.mapOrElse!(fv, fe)`](https://tchaloupka.github.io/expected/expected.mapOrElse.html)                   | [`res.map_or_else(fe, fv)`](https://doc.rust-lang.org/std/result/enum.Result.html#method.map_or_else)  |
| [Flatten Collection](#_2-flattening-collections-flatten)                         | [`range.joiner`](https://dlang.org/phobos/std_algorithm_iteration.html#joiner)                              | [`iter.flatten()`](https://doc.rust-lang.org/std/iter/trait.Iterator.html#method.flatten)              |

[expected-repo]: https://github.com/tchaloupka/expected
[Expected]: https://tchaloupka.github.io/expected/expected.Expected.html
[ok]: https://tchaloupka.github.io/expected/expected.ok.html
[err]: https://tchaloupka.github.io/expected/expected.err.html
[Abort]: https://tchaloupka.github.io/expected/expected.Abort.html
