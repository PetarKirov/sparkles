# Sean Parent's Better Code Philosophy

> "Good code is short, simple, and symmetrical—the challenge is figuring out how to get there." — Sean Parent

## Overview

Sean Parent is a Principal Scientist at Adobe Systems and one of the most influential voices in modern C++ development. His work spans decades of experience building large-scale software systems, most notably Adobe Photoshop. His "Better Code" series of talks and writings provides a comprehensive philosophy for writing correct, efficient, and maintainable software.

This documentation synthesizes his key ideas into actionable guidelines for developers.

## Core Philosophy

Sean Parent's approach to software development is built on several foundational principles:

1. **Local Reasoning** — Code should be understandable in isolation
2. **Value Semantics** — Prefer values over references and pointers
3. **Algorithm-Centric Design** — Use standard algorithms instead of raw loops
4. **Regular Types** — Implement types that behave predictably
5. **Explicit Relationships** — Make data relationships clear and intentional

## The Better Code Series

Sean Parent's "Better Code" talks form a comprehensive curriculum for software craftsmanship. While many are part of an explicit series, others provide foundational depth to the same core philosophy:

| Talk                                            | Goal                             | Key Principle                                         |
| ----------------------------------------------- | -------------------------------- | ----------------------------------------------------- |
| [C++ Seasoning](./cpp-seasoning.md)             | Three goals for better code      | No raw loops, no raw synchronization, no raw pointers |
| [Local Reasoning](./local-reasoning.md)         | Understand code in isolation     | Clear specifications and contracts                    |
| [Regular Types](./regular-types.md)             | Implement complete types         | Support basis operations                              |
| [Value Semantics](./value-semantics.md)         | Polymorphism without inheritance | Type erasure and concepts                             |
| [Algorithms](./algorithms.md)                   | Master standard algorithms       | Composition over raw loops                            |
| [Concurrency](./concurrency.md)                 | Software that doesn't wait       | Tasks and futures over threads                        |
| [Data Structures](./data-structures.md)         | No incidental data structures    | Intentional container choice                          |
| [Relationships](./relationships.md)             | Manage object connections        | Explicit relationship modeling                        |
| [Contracts](./contracts.md)                     | Prove correctness                | Preconditions, postconditions, invariants             |
| [Safety](./safety.md)                           | All the safeties                 | Memory, type, and thread safety                       |
| [Human Interface](./human-interface.md)         | Don't lie to users               | UI semantics match code semantics                     |
| [Generic Programming](./generic-programming.md) | Write reusable algorithms        | Concepts and constraints                              |
| [Runtime Polymorphism](./value-semantics.md)    | Non-intrusive polymorphism       | Value-based runtime polymorphism                      |
| [What's Your Function?](./algorithms.md)        | Good function design             | Function as the unit of reasoning                     |

## Other Notable Talks

- **Are We There Yet?** (2025) — Reflections on the future of software development 18 years later.
- **Chains: An alternative to sender/receivers** (2024) — Low-latency asynchronous composition.
- **Exceptions the Other Way Around** (2022) — Recovering from exceptions and developing usable operations.
- **Where Have All the Cycles Gone?** (2022) — Why software performance doesn't scale with hardware.
- **The Tragedy of C++** (2022) — Successes and gaps in the language's evolution.
- **Warning: std::find() is broken** (2021) — Questioning assumptions about core algorithms.
- **Compose This** (2019) — Limitations of functional composition and the need for a better theory.

## Foundational Papers

- **Local Reasoning Can Help Prove Correctness** (2025) — Deep dive into the mechanics of local reasoning.
- **indirect and polymorphic: Vocabulary Types for Composite Class Design** (2023) — Proposal for C++ standard vocabulary types.
- **Generating Reactive Programs for GUIs...** (2015) — Declarative approach to GUI programming and dataflow.
- **Property Models: From Incidental Algorithms to Reusable Components** (2008) — Capturing algorithms and interaction rules.
- **Elements of Programming, Appendix B** (2009) — Syntax and semantics for the language described in Stepanov's book.

## Key Themes

### 1. Raise the Level of Abstraction

Sean consistently advocates for working at higher levels of abstraction:

- Use algorithms instead of loops
- Use futures instead of threads
- Use smart pointers instead of raw memory management
- Use concepts instead of inheritance hierarchies

### 2. Make Intent Clear

Code should express _what_ it does, not _how_ it does it:

```cpp
// Bad: How (raw loop)
for (auto i = v.begin(); i != v.end(); ++i) {
    if (pred(*i)) {
        // process
    }
}

// Good: What (algorithm)
for_each(filter(v, pred), process);
```

### 3. Design for Composition

Software components should compose cleanly:

- Functions should be small and focused
- Types should be regular (copyable, comparable)
- Side effects should be explicit and contained
- Dependencies should be minimal and declared

### 4. Embrace Constraints

Constraints make code safer and more expressive:

- Use `const` liberally
- Specify preconditions and postconditions
- Define clear ownership semantics
- Make illegal states unrepresentable

## Influences and Foundations

Sean Parent's work builds on several intellectual foundations:

### Alexander Stepanov & Elements of Programming

The mathematical foundations of generic programming, regular types, and algorithm design from Stepanov's work with the STL and his book "Elements of Programming" (co-authored with Paul McJones) deeply influence Sean's approach.

### Dave Abrahams

Collaboration on exception safety, contracts, and the foundations of correct C++ code.

### Functional Programming

Ideas from functional programming—immutability, pure functions, composition—inform the emphasis on value semantics and declarative style.

## Resources

### Primary Sources

- **[Papers and Presentations](https://sean-parent.stlab.cc/papers-and-presentations/)** — Complete archive of Sean's talks and papers
- **[STLab](https://stlab.cc/)** — Adobe's Software Technology Lab libraries
- **[Adobe Developer C++ Training](https://developer.adobe.com/cpp/training/)** — Internal Adobe talks made public

### Key Interviews & Podcasts

- **ADSP: The Podcast** — Frequent guest covering AI, Rust, Safety, and C++ history (Episodes 250-253, 202-203, 172, 160-163, etc.).
- **CppCast** — Interviews on Concurrency (2015) and STLab (2021).
- **Meeting C++ AMA** (2022) — Open Q&A session.

### Key Talks (Recommended Viewing Order)

1. **C++ Seasoning** (GoingNative 2013) — Introduction to the three goals
2. **Value Semantics and Concept-based Polymorphism** (C++Now 2012) — Foundation for type design
3. **Better Code: Concurrency** (NDC London 2017) — Task-based concurrency model
4. **Local Reasoning in C++** (NDC TechTown 2024) — Latest synthesis of principles
5. **All the Safeties** (C++ on Sea 2023) — Safety taxonomy and modern concerns

### Books

- **Elements of Programming** by Alexander Stepanov and Paul McJones
- **From Mathematics to Generic Programming** by Alexander Stepanov and Daniel Rose

## Applying These Principles

These principles are language-agnostic in spirit, though the examples are C++ focused. The key ideas translate to any language:

| Principle       | C++                               | D                               | Rust             | Other Languages           |
| --------------- | --------------------------------- | ------------------------------- | ---------------- | ------------------------- |
| Value Semantics | Copy constructors, move semantics | `@disable this(this)`, postblit | Ownership, Clone | Immutable data structures |
| Algorithms      | `<algorithm>`                     | `std.algorithm`                 | Iterator traits  | Map, filter, reduce       |
| Contracts       | `assert`, C++20 contracts         | `in`/`out` contracts            | `debug_assert!`  | Design by Contract        |
| Regular Types   | Rule of 5                         | Default operations              | Derive traits    | Protocol conformance      |

## Document Structure

Each topic document follows this structure:

1. **Overview** — What the concept is and why it matters
2. **Core Principles** — The fundamental ideas
3. **Guidelines** — Actionable rules to follow
4. **Examples** — Code demonstrating the principles
5. **Anti-patterns** — Common mistakes to avoid
6. **References** — Links to original talks and papers

---

_"The purpose of abstraction is not to be vague, but to create a new semantic level in which one can be absolutely precise."_ — Edsger Dijkstra (often quoted by Sean Parent)
