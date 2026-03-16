# Comparison of Effect System Proposals

This document compares **Proposal A: Direct-Style** and **Proposal B: Effect-TS Style** for implementing algebraic effects in D.

## Overview

| Feature             | Proposal A: Direct-Style                     | Proposal B: Effect-TS Style                 |
| :------------------ | :------------------------------------------- | :------------------------------------------ |
| **Core Paradigm**   | Imperative, capability-passing               | Functional, monadic builder                 |
| **Execution**       | Immediate (direct calls)                     | Deferred (interpreter loop)                 |
| **Control Flow**    | Native D (`if`, `while`, `try`, `scope`)     | Monadic combinators (`flatMap`, `catchAll`) |
| **Effect Tracking** | Explicit boundary checks (`supportsEffect!`) | Encoded in return type (`Effect!(T, E, R)`) |
| **Error Handling**  | Native exceptions or tagged values           | Type-level union (`std.sumtype`)            |
| **Dependencies**    | Explicit `Context` struct / Handles          | `provide()` chaining                        |

---

## 1. Ergonomics and Control Flow

### Direct-Style

- **Pros:** It looks and feels like standard D code. You can use standard loops (`foreach`), conditionals (`if`), and native RAII (`scope(exit)`) without any friction.
- **Cons:** You must manually pass around `Context` or individual handles.

### Effect-TS Style

- **Pros:** Extremely elegant pipeline operations. Function signatures explicitly describe exactly what can fail and what is needed, requiring no manual context threading.
- **Cons:** Loss of native control flow. You cannot put a `flatMap` inside a `foreach` easily; you must use a library-provided `Effect.forEach`. Native `scope(exit)` does not run when you think it does (it runs when the AST is built, not when the effect executes).

## 2. Type Safety & Exhaustiveness

### Direct-Style

- **Pros:** Enforced at the boundary API level. Missing requirements trigger compile-time constraint failures.
- **Cons:** D's exception system does not track checked exceptions. Error handling relies on discipline or returning `Result` types, rather than being an intrinsic part of the effect row.

### Effect-TS Style

- **Pros:** Absolute type safety. The compiler forces you to handle every specific error explicitly using `std.sumtype` and `match!`. You cannot accidentally miss an error case.
- **Cons:** The type signature of deeply nested pipelines can become complex, though the use of `noreturn` and `std.sumtype` heavily mitigates this.

## 3. Performance and Compilation

### Direct-Style

- **Pros:**
  - Zero-allocation fast path. Operations are direct interface or struct method calls.
  - Highly compatible with `@nogc`, `@safe`, `pure`, and `nothrow`.
  - Fast compile times since it does not rely on massive recursive template instantiations.
  - Native D stack traces point exactly to the failing line of code.
- **Cons:** Threading context adds slight parameter-passing overhead (though usually optimized out via inlining).

### Effect-TS Style

- **Pros:** Dead code elimination is possible when an effect returns `noreturn`.
- **Cons:**
  - **Allocation:** Passing closures (lambdas) to `flatMap` often forces closure allocation on the GC heap, making strict `@nogc` difficult.
  - **Compile Times:** Instantiating new struct types for every operation in a chain can degrade compilation speeds in large projects.
  - **Stack Traces:** Stack traces point to the interpreter loop (`runSync`), not the user code that failed, requiring complex trace-reconstruction machinery.

## Conclusion

- Choose **Proposal A (Direct-Style)** if the priority is systems-level performance, `@nogc` compatibility, fast compilation, and seamless integration with D's RAII and native control flow.
- Choose **Proposal B (Effect-TS Style)** if the priority is absolute correctness, purely functional pipelines, exhaustive error tracking, and developers are comfortable sacrificing native control flow for monadic combinators.
