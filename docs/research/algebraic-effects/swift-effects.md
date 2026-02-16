# Swift's Effect System (Swift)

A modern implementation of effect tracking in a mainstream systems language, combining async/await, typed throws, and effectful properties with a strong focus on data-race safety.

| Field         | Value                                                                      |
| ------------- | -------------------------------------------------------------------------- |
| Language      | Swift 6.x                                                                  |
| License       | Apache-2.0                                                                 |
| Repository    | [github.com/swiftlang/swift](https://github.com/swiftlang/swift)           |
| Documentation | [swift.org](https://swift.org/documentation/concurrency/)                  |
| Key Authors   | John McCall, Joe Groff, Doug Gregor                                        |
| Approach      | Keyword-based effect specifiers (async, throws) with full data-race safety |

---

## Overview

### What It Solves

Swift's effect system addresses the dual challenges of managing non-local control flow (errors and asynchrony) and ensuring memory safety in concurrent programs. Unlike many other languages that treat `async` or `throws` as isolated features, Swift integrates them into its type system as **effect specifiers**. This allows the compiler to enforce structured concurrency and data-race safety at the function boundary.

### Design Philosophy

Swift prioritizes **Approachable Concurrency** (introduced in Swift 6.2). The design aims to make concurrent and effectful programming as intuitive as sequential programming while maintaining strict safety guarantees. It uses a "keyword-based" approach rather than a general algebraic effect system, choosing predictability and performance over arbitrary effect extensibility.

---

## Core Abstractions and Types

### Effect Specifiers

Swift uses `async` and `throws` as effect specifiers on function signatures:

```swift
func fetchData(id: UUID) async throws -> Data {
    // Both asynchrony and fallibility are tracked
}
```

By 2026, Swift has expanded these to **Effectful Properties** (SE-0310), allowing read-only computed properties to be both `async` and `throws`.

### Typed Throws

Introduced in Swift 6, **Typed Throws** allow specifying the exact error type:

```swift
func parseConfig() throws(ParseError) -> Config {
    // Must throw ParseError specifically
}
```

This brings Swift closer to full algebraic error tracking, similar to `Result<T, E>` in Rust or `Effect<A, E, R>` in TypeScript, but with the ergonomics of native language keywords.

### Data-Race Safety (Sendable)

The `Sendable` protocol is Swift's mechanism for tracking the "sharing effect." The compiler ensures that values passed across concurrency boundaries are safe to share, preventing data races at compile time.

---

## How Handlers/Interpreters Work

### do-catch and await

Swift does not have "handlers" in the algebraic sense (with resumption). Instead, it uses standard structured control flow:

- `do-catch` blocks "handle" the `throws` effect.
- `await` points "suspend" the `async` effect, with the runtime managing the resumption.

### Actors and Isolation

Actors serve as a "contextual handler" for concurrency. Code running within an actor is isolated from other concurrent tasks, ensuring that internal state is modified sequentially.

---

## Strengths

- **Language-level integration**: Effects are built into the syntax and checked by the compiler.
- **Data-race safety**: Compile-time enforcement of thread safety via `Sendable` and actors.
- **Approachable ergonomics**: `async/await` and `throws` read like natural language.
- **Performance**: Native runtime support for task scheduling and stack-safe error propagation.

## Weaknesses

- **Fixed effect set**: Cannot define custom effect types (e.g., `State` or `Reader`).
- **No resumption**: Once an error is thrown, the continuation is lost (unlike true algebraic effects).
- **Under construction**: The concurrency model continues to evolve significantly across 6.x versions.

---

## Sources

- [Swift Concurrency Manifest](https://github.com/swiftlang/swift/blob/main/docs/Concurrency/Manifesto.md)
- [SE-0310: Effectful Read-only Properties](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0310-effectful-readonly-properties.md)
- [SE-0413: Typed Throws](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md)
