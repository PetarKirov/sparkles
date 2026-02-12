# Better Code: Chains (An Alternative to Sender/Receivers)

> "Instead of launching async code and attaching continuation, we build a _program_ — a function — that describes the async operation and then start that. This program is built flat, without heap allocations, with no need for synchronization because the connections are made before it starts." — Sean Parent, NYC++ 2024

## Overview

"Chains: Exploration of an alternative to Sender/Receiver" was first presented by Sean Parent at the NYC++ Meetup on March 7, 2024. The talk begins from the separation of a function's execution context from its result, explores the resulting problem space, and pursues an alternative path to P2300 sender/receivers — emphasizing **simplicity and low latency in a dynamic environment**.

Chains emerged from Sean Parent's years of experience building latency-sensitive interactive applications at Adobe (Lightroom, Revel, Camera Raw) and from the `stlab` concurrency library he created to address the limitations of `std::future` and Boost futures. The proposal is explicitly **experimental** — Parent notes he was only two weeks into working on chains at the time of the talk, and acknowledges he may "just rediscover the complexity of sender/receivers."

The experimental library is available at [github.com/stlab/chains](https://github.com/stlab/chains).

## Historical Context

### The Lightroom Browser Problem (2015)

In 2015, Parent was involved in bringing Adobe Lightroom to the browser under asm.js — a **single-threaded** model. Lightroom is a multi-threaded application. The code had to be transformed so it could run single-threaded _and_ scale to run efficiently on many cores. This forced a rethinking of concurrency abstractions.

### Boost Futures — The First Attempt

Parent's first thought was to use Boost futures with continuations:

```cpp
auto f = make_ready_future(42);
auto f0 = f.then([](auto a){ return a.get() + 2; });
auto f1 = move(f).then([](auto a){ return a.get() + 3; });
```

The second line crashed — with Boost futures, `then()` is a **consuming** operation. You could not attach multiple continuations to the same future. This and other issues led Parent to create the `stlab` concurrency library — "written almost entirely in the hotel bar at C++Now."

### stlab Futures

The `stlab` library addressed the shortcomings:

- **Regular (Copyable)**: Unlike `std::future`, `stlab::future` is copyable — enabling splits (multiple continuations on the same future)
- **RAII Cancellation**: Destruction of a future cancels its associated task — "RAII applies to the processor, arguably even more important a resource than memory"
- **Efficient Cancellation**: A dependency graph is a bipartite DAG of operations and results; canceling a result cancels only its uniquely contributing operations

```cpp
auto a = f | g;  // continuation
auto b = f | h;  // split — both use same future
```

### The Problem with the Solution

The programming model presented by futures with continuations is deceptively simple — **but every continuation comes at a cost**:

- A small object allocation/deallocation: **200-500 cycles**
- Every atomic operation: **15-30 cycles**
- The overhead of an async continuation vs. sequential function composition: **100-1000x**

We only want to attach continuations when the operation is significantly large or a specific execution context is required. The simple syntax of `f | g` means continuations get used for simple function composition — at a very measurable cost.

### Don't Use Continuations as Expensive Function Composition

If you know the continuation in advance, don't write:

```cpp
auto a = async(f) | g;
```

But instead write:

```cpp
auto a = async(compose(g, f));
```

But this doesn't compose well — an async operation now needs to take a callback so it can compose the operation prior to starting it. The complexity grows rapidly. What if instead of _starting_ the async operations, we simply _described_ them?

## Sender/Receivers Are Function Composition

This is the insight that motivates both P2300 and Chains. The sender/receiver model builds a **program** (a function) that describes the async operation, then starts it:

| Sender/Receiver Expression          | Equivalent                     |
| :---------------------------------- | :----------------------------- |
| `then(f) \| then(g)`                | `compose(g, f)`                |
| `transfer(s) \| then(f)`            | `bind_front(s, f)`             |
| `transfer(s) \| then(f) \| then(g)` | `bind_front(s, compose(g, f))` |

This composition pattern is **obscured** by the complex sender/receiver interface. P2300 carries the complexity of signaling cancellations and exceptions at _every step_ — three channels (`set_value`, `set_error`, `set_stopped`) must be handled at each stage.

Chains pursue the same fundamental idea — building a program upfront — but with a simpler model.

## The Chains Model

### Core Concepts

The model has three layers that build on each other:

#### 1. Links — Flat Function Composition

A **link** is just a function. Links are stored as a **flat sequence** — they form a single logical function without nesting.

```
... f | g | h
```

The desired result is `compose(h, compose(g, f))` — but **without the nesting**. Nesting blows the stack. Instead, links are stored in a tuple and composed via fold expressions at invocation time.

```
┌───┐    ┌───┐    ┌───┐
│ f │───>│ g │───>│ h │
└───┘    └───┘    └───┘
```

Since this is simple function composition, exceptions propagate naturally — if `f` throws in `h(g(f(x)))`, neither `g` nor `h` can catch it. This is the same as `std::expected`'s `and_then` chaining. We only need a sequence of functions to describe the computation.

#### 2. Segments — Links with Execution Context

A **segment** is an **applicator** bound to a sequence of links. The applicator determines the _context_ in which the links execute (e.g., a thread pool, GPU, serial queue).

`on(s) | f | g` is logically `bind_front(s, f | g)` — but the structure is stored, not evaluated:

```
            ┌ ─ ─ ─ ─ ─ ┐
┌───────┐   │ ┌───┐  ┌───┐│
│ on(s) │<──  │ f │─>│ g │
└───────┘   │ └───┘  └───┘│
             ─ ─ ─ ─ ─ ─ ─
applicator      links
```

A segment logically forms a single function. Additional links can be appended to the segment before execution.

**Example — an "expector" applicator** that maps exceptions to `std::expected`:

```cpp
auto expector = [](auto f, auto... args) -> expected<...> {
    try { return f(args...); }
    catch (...) { return current_exception(); }
};

(on(expector) | badd | [](int x){ return x * 2; })(12, 5);
// => expected{34}
```

#### 3. Chains — Sequences of Segments

A **chain** is a sequence of segments. Chains are **two-dimensional data structures** — we can append links to the end of the last segment, or append new segments to the end of the chain:

```
on(s) | f | g | on(t) | h | on(u) | i | j | k
```

```
             ┌ ─ ─ ─ ─ ─ ┐
 ┌───────┐   │ ┌───┐  ┌───┐│
 │ on(s) │<──  │ f │─>│ g │
 └───────┘   │ └───┘  └───┘│
              ─ ─ ─ ─ ─ ─ ─
             ┌ ─ ─ ─┐
 ┌───────┐   │ ┌───┐ │
 │ on(t) │<──  │ h │
 └───────┘   │ └───┘ │
              ─ ─ ─ ─
             ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
 ┌───────┐   │ ┌───┐  ┌───┐  ┌───┐│
 │ on(u) │<──  │ i │─>│ j │─>│ k │
 └───────┘   │ └───┘  └───┘  └───┘│
              ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
```

Chains are stored as a **tuple of tuples of functions** — flat, with no heap allocations. The chain is executed by appending each segment to the end of the prior segment, so the result of one segment is passed as an argument to the next. A chain is logically a single function.

### Mapping to Async

A chain is a program that _describes_ the sequence of execution. To make it asynchronous:

1. Create segments that provide an **execution context** to schedule work (via `on(executor)`)
2. Append a **promise** to the end of the chain, returning a **future**
3. Bind a **stop token** and `set_exception` operation to every applicator — instead of wrapping individual operations

```
             ┌ ─ ─ ─ ─ ─ ┐
 ┌───────┐   │ ┌───┐  ┌───┐│
 │ on(s) │<──  │ f │─>│ g │    ─┐
 └───────┘   │ └───┘  └───┘│    │ segments are linked:
              ─ ─ ─ ─ ─ ─ ─     │ the next segment is
             ┌ ─ ─ ─┐           │ appended to the
 ┌───────┐   │ ┌───┐ │          │ prior segment
 │ on(t) │<──  │ h │        ─┘
 └───────┘   │ └───┘ │
              ─ ─ ─ ─
             ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
 ┌───────┐   │ ┌───┐  ┌───┐  ┌───┐  ┌───┐│
 │ on(u) │<──  │ i │─>│ j │─>│ k │─>│ p │   <── promise (future)
 └───────┘   │ └───┘  └───┘  └───┘  └───┘│
              ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
```

Having access to the structure allows operations to make transformations. **Errors only need to be caught and propagated from the segment level** (same for cancellation) — not at every individual link.

### Error Handling and Cancellation

Each segment's `invoke` method:

1. Checks the **receiver** for cancellation — if canceled, returns immediately
2. Composes all links in the segment into a single function via `tuple_compose`
3. Executes the composed function
4. Catches any exception and propagates it to the receiver via `set_exception`

This is significantly simpler than P2300's three-channel model, where every stage must independently handle value, error, and stopped signals. In Chains, errors are caught at **segment boundaries** — the natural points where execution context changes.

## Implementation Details

### `tuple_compose` — The Core Primitive

The foundation of Chains is `tuple_compose`, which takes a tuple of functions and returns a single composed callable. It uses C++ fold expressions to apply functions left-to-right, with `void_to_monostate` converting void returns to `std::monostate` for uniform chaining:

```cpp
// From stlab/chains — include/chains/tuple.hpp
template <class... Fs>
auto tuple_compose(std::tuple<Fs...>&& sequence) {
    return [_sequence = std::move(sequence)](auto&&... args) mutable {
        return std::move(std::apply(
            [_args = std::forward_as_tuple(std::forward<decltype(args)>(args)...)](
                auto& first, auto&... functions) mutable {
                return (detail::tuple_pipeable{std::apply(first, std::move(_args))}
                        | ... | functions);
            },
            _sequence)._value);
    };
}
```

### `segment<Applicator, Fs...>`

A segment stores an applicator and a tuple of link functions. Its `invoke` method integrates cancellation and error handling:

```cpp
template <class R, class... Args>
void invoke(const R& receiver, Args&&... args) && {
    if (receiver.canceled()) return;

    std::move(_apply)(
        [_f = tuple_compose(std::move(_functions)),
         _receiver = receiver](auto&&... args) mutable noexcept {
            if (_receiver.canceled()) return;
            try {
                std::move(_f)(std::forward<decltype(args)>(args)...);
            } catch (...) {
                _receiver.set_exception(std::current_exception());
            }
        },
        std::forward<Args>(args)...);
}
```

### `chain<Tail, Applicator, Fs...>`

A chain manages a sequence of segments. When invoked, it creates a `stlab::package` (promise/future pair) and returns a future:

```cpp
template <class... Args>
auto operator()(Args&&... args) && {
    using result_t = result_type<Args...>;
    auto [receiver, future] =
        stlab::package<result_t(result_t)>(stlab::immediate_executor, std::identity{});
    (void)std::move(*this).expand(receiver)(std::forward<Args>(args)...);
    return std::move(future);
}
```

### `on(executor)` — The Scheduling Primitive

The `on` function creates a segment whose applicator schedules work on a given executor:

```cpp
template <class E>
inline auto on(E&& executor) {
    return segment{[_executor = std::forward<E>(executor)](auto&& f, auto&&... args) mutable {
        std::move(_executor)(
            [_f = std::forward<decltype(f)>(f),
             _args = std::tuple{std::forward<decltype(args)>(args)...}]() mutable noexcept {
                std::apply(std::move(_f), std::move(_args));
            });
        return std::monostate{};
    }};
}
```

### Usage

```cpp
auto a0 = on(default_executor) | [] {
    cout << "Hello from thread: " << this_thread::get_id() << "\n";
    return 42;
};

auto a1 = std::move(a0) | on(default_executor) | [](int x) {
    cout << "received: " << x << " on thread: " << this_thread::get_id() << "\n";
    return "forwarding: " + std::to_string(x + 1);
};

// Start the chain and await the result
std::cout << await(std::move(a1)()) << "\n";
```

## Comparison

| Feature             | Futures/Continuations   | Sender/Receivers (P2300) | Chains                     |
| :------------------ | :---------------------- | :----------------------- | :------------------------- |
| **Allocation**      | Per-continuation (heap) | None (stack/inline)      | None (tuple of tuples)     |
| **Complexity**      | Low (API), High (cost)  | Very High                | Low                        |
| **Error Model**     | Exception propagation   | Three channels per stage | Exception at segment level |
| **Latency**         | High (sync per step)    | Low                      | Low (no per-link overhead) |
| **Local Reasoning** | High                    | Low (complex signatures) | High                       |
| **Cancellation**    | RAII (stlab)            | Stop tokens per stage    | Checked at segment level   |
| **Maturity**        | Production (stlab)      | Standardized (C++26)     | Experimental prototype     |

## The Split Problem

Chains shift from a model of "functions with detached results" to one of "functions _as_ results." This raises a fundamental question: **what does it mean to split a function?**

Splitting requires:

- Synchronization
- The shared portion should be executed once
- Canceling should only cancel the non-shared portion
- Must have no arguments; first invocation starts, subsequent invocations are ignored

Parent notes that the current sender/receiver implementation of `split` is broken with respect to cancellation. `let_value()` provides a form of split for computation, but the split must be contained within a rejoin. This remains an open problem for both models.

## Chains vs. Sender/Receivers — Philosophical Difference

From the talk (slide 59):

- **Chains** are a general-purpose facility to build **functional descriptions** (programs) in C++
- **Sender/Receivers** are a language within which to build **asynchronous descriptions** — they don't _have_ to be used for asynchronous descriptions, but they carry the complexity of signaling cancellations and exceptions at every step

Parent believes that chains with an S & K combinator may be **Turing complete** (proof in progress at the time of the talk).

## Limitations and Open Questions

Parent is candid about the state of the work:

- "Chains can't currently do anything that sender/receivers can't do. But the model is simpler."
- "I'm only two weeks into working on chains, and each step has been challenging. I may just rediscover the complexity of sender/receivers."
- The prototype is missing production features: void result types everywhere, minimizing copies, handling perfect forwarding and move-only types, handling copy everywhere appropriate
- The entire structure of the program is carried in the type system — "I suspect I'll hit implementation limits, however, my types are less complex than sender-receiver types"
- A structured form for the complete "program" may have advantages for scheduling (especially on GPUs)
- "At the very least the process of thinking through and building chains has greatly improved my understanding of Sender/Receivers and where the complexity comes from."

## Why Sync Wait Breaks Everything

A key motivation for both futures-with-continuations and chains is avoiding synchronous waits. From the talk:

- On a single-threaded system, a sync wait is a **deadlock** — the queued task will never complete because the only thread is blocked
- On a multi-threaded system, sync waits can still deadlock — spawned tasks may exhaust available threads
- **Amdahl's Law**: With only 10% serialization, performance on 16 cores is only slightly more than 6x — and will never exceed 10x regardless of processor count
- Any sync wait requires **non-local reasoning** about where tasks are scheduled, what tasks they may spawn, and how many threads are available — this leads to the "function color problem"

## Guidelines

### 1. Don't Use Continuations as Expensive Function Composition

If you know the continuation in advance, compose the functions _before_ launching async work. Continuations should mark scheduling boundaries, not function calls.

### 2. Separate Context from Logic

Write business logic as simple functions (links). Use applicators to decide _where_ those functions run. This preserves **local reasoning** — the function doesn't know or care about its execution context.

### 3. Build Upfront, Execute Later

A chain is a program that describes the sequence of execution. Define it once, then invoke it. The structure is known before any execution begins, enabling optimizations and avoiding per-step allocation.

### 4. Errors and Cancellation at Segment Boundaries

Don't handle errors at every function. Catch exceptions and check cancellation at **segment boundaries** — the natural points where execution context changes. This matches how errors actually propagate in function composition.

## References

### Primary Sources

- **[Chains: Exploration of an alternative to Sender/Receiver (YouTube)](https://youtu.be/nQpXOx0D7I8)** — NYC++ Meetup, March 7, 2024
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2024-03-07-chains/2024-03-07-chains.pdf)** — March 2024
- **[Annotated Slides with Speaker Notes (PDF)](https://sean-parent.stlab.cc/presentations/2024-03-07-chains/2024-03-07-chains-notes.pdf)** — March 2024
- **[stlab/chains (GitHub)](https://github.com/stlab/chains)** — Experimental implementation

### Background

- **[Better Code: Concurrency (YouTube)](https://www.youtube.com/watch?v=zULU6Hhp42w)** — NDC London 2017 (the stlab futures talk)
- **[Future Ruminations (Blog)](https://sean-parent.stlab.cc/2017/07/10/future-ruminations.html)** — Design rationale for stlab futures, separation of execution context from result
- **[stlab Concurrency Library](https://stlab.cc/libraries/)** — Production futures/channels library underlying Chains
- **[ADSP Episode 172: Sean Parent on Flash, Chains & Memory Safety](https://adspthepodcast.com/2024/03/08/Episode-172.html)** — Podcast discussion of Chains (March 2024)
- **[Papers and Presentations](https://sean-parent.stlab.cc/papers-and-presentations/)** — Complete archive of Sean Parent's talks

### Context on P2300 Sender/Receivers

- **[What are Senders Good For, Anyway?](https://ericniebler.com/2024/02/04/what-are-senders-good-for-anyway/)** — Eric Niebler's explanation of the P2300 design rationale
- **[Sender Intuition: Senders Don't Send](https://benfrantzdale.github.io/blog/2024/10/01/sender-intuition-senders-dont-send.html)** — Notes that synchronous sender composition "is just a long way to compose functions (as Sean Parent points out)"

---

_"The simple syntax of futures with continuations means they get used for simple function composition — at a high, very measurable cost."_ — Sean Parent, NYC++ 2024
