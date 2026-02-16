# Project Loom (Java)

Virtual threads, structured concurrency, and scoped values -- Java's platform-level approach to lightweight concurrency, built on hidden continuations inside the JVM.

| Field         | Value                                                           |
| ------------- | --------------------------------------------------------------- |
| Language      | Java 21+                                                        |
| License       | GPL-2.0 with Classpath Exception (OpenJDK)                      |
| Repository    | [github.com/openjdk/loom](https://github.com/openjdk/loom)      |
| Documentation | [openjdk.org/projects/loom](https://openjdk.org/projects/loom/) |
| Key Authors   | Ron Pressler, Alan Bateman (Oracle)                             |
| Approach      | JVM-managed virtual threads with hidden delimited continuations |

---

## Overview

### What It Solves

Java's traditional concurrency model maps each Java thread one-to-one to an OS platform thread. Platform threads are expensive: each requires roughly 2 MB of stack memory and involves kernel-level scheduling. This makes the thread-per-request model -- the natural way to write server applications -- unable to scale beyond a few thousand concurrent connections without resorting to asynchronous frameworks (reactive streams, callbacks, CompletableFuture chains) that sacrifice readability and debuggability.

Project Loom solves this by introducing virtual threads: lightweight threads managed entirely by the JVM that can number in the millions, restoring the simplicity of thread-per-request programming at any scale.

### Design Philosophy

Loom's philosophy is conservative integration: rather than exposing new programming models or algebraic effect abstractions, it makes the existing `java.lang.Thread` API work at scale. Virtual threads are `Thread` instances -- they work with `synchronized`, `ThreadLocal`, `try/catch`, debuggers, and profilers. The goal is that existing code benefits from virtual threads with minimal or no changes.

---

## Core Abstractions and Types

### Virtual Threads (JEP 444 -- Final in Java 21)

Virtual threads are lightweight threads scheduled by the JVM rather than the operating system. They are multiplexed onto a small pool of carrier threads (platform threads managed by a `ForkJoinPool`):

```java
// Create and start a virtual thread
Thread.startVirtualThread(() -> {
    var result = fetchFromDatabase();  // blocks without wasting OS thread
    process(result);
});

// Using the builder API
Thread vt = Thread.ofVirtual()
    .name("worker-", 0)
    .start(() -> handleRequest(request));

// Using an executor (typical server pattern)
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    for (var request : incomingRequests) {
        executor.submit(() -> handleRequest(request));
    }
}
```

When a virtual thread blocks on I/O (socket read, file read, `Thread.sleep`, lock acquisition), the JVM unmounts it from the carrier thread, freeing the carrier to run other virtual threads. When the I/O completes, the virtual thread is remounted onto an available carrier and resumes execution. This is invisible to application code.

### Structured Concurrency (JEP 453 -- Preview)

`StructuredTaskScope` treats a group of concurrent subtasks as a single unit of work with well-defined lifecycle guarantees:

```java
record UserProfile(User user, List<Order> orders) {}

UserProfile fetchProfile(String userId) throws Exception {
    try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
        Subtask<User> userTask = scope.fork(() -> findUser(userId));
        Subtask<List<Order>> ordersTask = scope.fork(() -> fetchOrders(userId));

        scope.join();            // wait for both subtasks
        scope.throwIfFailed();   // propagate first failure

        return new UserProfile(userTask.get(), ordersTask.get());
    }
    // If either subtask fails, the other is cancelled automatically
}
```

Policies control how the scope responds to subtask completion:

| Policy              | Behavior                                            |
| ------------------- | --------------------------------------------------- |
| `ShutdownOnFailure` | Cancel remaining subtasks when any subtask fails    |
| `ShutdownOnSuccess` | Cancel remaining subtasks when any subtask succeeds |

Subtasks forked within a scope run as virtual threads. The scope ensures that no subtask outlives the scope itself, preventing thread leaks.

### Scoped Values (JEP 464 -- Preview)

Scoped values provide implicit, immutable context propagation through the call stack -- analogous to a Reader effect in algebraic effect systems:

```java
private static final ScopedValue<String> CURRENT_USER = ScopedValue.newInstance();

// Bind a scoped value for a bounded region of code
ScopedValue.runWhere(CURRENT_USER, "alice", () -> {
    handleRequest();  // CURRENT_USER.get() returns "alice" here and in all callees
});

// Nested rebinding
void handleRequest() {
    String user = CURRENT_USER.get();  // "alice"
    ScopedValue.runWhere(CURRENT_USER, "system", () -> {
        auditLog();  // CURRENT_USER.get() returns "system"
    });
    // CURRENT_USER.get() returns "alice" again
}
```

Scoped values improve on `ThreadLocal` in several ways:

| Property     | ThreadLocal                   | ScopedValue                        |
| ------------ | ----------------------------- | ---------------------------------- |
| Mutability   | Mutable (set/get)             | Immutable per binding scope        |
| Lifetime     | Unbounded (manual cleanup)    | Bounded to `runWhere` scope        |
| Inheritance  | Copied to child threads       | Shared with structured concurrency |
| Memory leaks | Common (forgotten `remove()`) | Impossible by design               |
| Performance  | Hash map lookup               | Cached after first access          |

---

## How Effects Are Declared

Loom does not expose an explicit effect declaration mechanism. Instead, effects are implicit in the JVM's threading model:

- **Blocking I/O** is the primary "effect" -- virtual threads yield their carrier automatically on blocking calls
- **Context propagation** uses scoped values rather than an explicit Reader effect
- **Concurrency** uses structured task scopes rather than explicit Fork/Join effects
- **Error handling** uses Java's existing exception mechanism

This is a deliberate design choice: Java developers write ordinary sequential code, and the JVM runtime handles the underlying continuation mechanics transparently.

---

## How Handlers/Interpreters Work

### The Hidden Continuation

Internally, virtual threads are implemented using a `jdk.internal.vm.Continuation` class -- a scoped, stackful, one-shot delimited continuation. This class is not part of the public API:

```
jdk.internal.vm.Continuation
    - yield(ContinuationScope scope)  // suspend execution
    - run()                            // resume execution
```

When a virtual thread encounters a blocking operation:

1. The JVM calls `Continuation.yield(scope)`, capturing the current stack
2. The carrier thread is released to the `ForkJoinPool`
3. When the blocking condition resolves, `Continuation.run()` resumes the virtual thread on an available carrier

This is structurally identical to how algebraic effect handlers work: an effect (blocking I/O) is "thrown" upward and caught by the nearest matching handler (the virtual thread scheduler), which decides how and when to resume the continuation.

### Why Continuations Are Not Public

The Loom team considered exposing continuations as a public API but decided against it for several reasons:

- **Safety**: Continuations can violate thread identity (`Thread.currentThread()` can change mid-method)
- **Complexity**: Low-level continuation manipulation is error-prone and rarely needed directly
- **Sufficiency**: Virtual threads, structured concurrency, and scoped values cover the primary use cases
- **Compatibility**: A public continuation API would be difficult to evolve without breaking changes

The `Continuation` class remains in `jdk.internal.vm` and requires `--add-exports` flags to access directly.

---

## Performance Approach

### Virtual Thread Overhead

Virtual threads are extremely lightweight compared to platform threads:

| Metric                  | Platform Thread | Virtual Thread          |
| ----------------------- | --------------- | ----------------------- |
| Stack memory            | ~2 MB (fixed)   | ~1 KB (grows as needed) |
| Creation cost           | ~1 ms           | ~1 us                   |
| Context switch          | Kernel-level    | User-level (JVM)        |
| Maximum practical count | ~5,000          | Millions                |

### Benchmark Results

Performance gains depend heavily on workload type:

- **I/O-bound workloads**: Virtual threads can achieve 8-10x throughput improvements over platform threads under high concurrency, because blocked virtual threads do not consume carrier threads
- **High concurrency (>5,000 connections)**: Platform threads degrade rapidly; virtual threads maintain consistent performance
- **CPU-bound workloads**: Virtual threads offer no advantage and can underperform due to `ForkJoinPool` scheduling overhead (observed as low as 50-55% throughput in some benchmarks)
- **Memory**: Virtual threads use roughly 100x less memory per thread than platform threads

### Pinning

A virtual thread becomes "pinned" to its carrier thread when it blocks inside a `synchronized` block or a native method. Pinned threads cannot yield, reducing the effective carrier pool size. The JVM can detect and report pinning via `-Djdk.tracePinnedThreads=full`. Replacing `synchronized` with `ReentrantLock` eliminates pinning.

---

## Composability Model

### Relation to Algebraic Effects

Loom's features map to a subset of what a full algebraic effect system provides:

| Algebraic Effect Concept    | Loom Equivalent                            |
| --------------------------- | ------------------------------------------ |
| Async/IO effect             | Virtual thread blocking (implicit yield)   |
| Reader effect               | `ScopedValue`                              |
| Fork/Join effect            | `StructuredTaskScope`                      |
| Error effect                | Java exceptions                            |
| State effect                | Not provided (use `AtomicReference`, etc.) |
| Nondeterminism              | Not provided                               |
| Custom user-defined effects | Not provided                               |
| Effect handlers (resume)    | Not exposed (internal `Continuation`)      |

Loom provides the three most practically important effects (async I/O, context propagation, structured concurrency) without requiring developers to learn effect system concepts. However, it does not support user-defined effects or custom handlers.

### Impact on the Java Ecosystem

Virtual threads reduce the need for reactive frameworks:

- **Before Loom**: Libraries like Project Reactor and RxJava were necessary for scalable I/O because platform threads could not scale. These frameworks imposed a callback/stream-based programming model.
- **After Loom**: Simple thread-per-request code achieves comparable scalability, making reactive frameworks unnecessary for many use cases. Frameworks like Spring Boot, Tomcat, and Jetty now support virtual threads natively.

However, reactive frameworks still provide value for backpressure, stream processing, and complex event-driven architectures that go beyond simple request-response patterns.

---

## Strengths

- **Zero learning curve**: Virtual threads are `Thread` instances; existing Java code works without changes
- **Ecosystem compatibility**: Works with debuggers, profilers, thread dumps, existing libraries
- **Massive scalability**: Millions of concurrent threads with minimal memory overhead
- **Structured concurrency**: Prevents thread leaks and simplifies concurrent error handling
- **Scoped values**: Safe, bounded context propagation without `ThreadLocal` pitfalls
- **Production-ready**: Virtual threads are a final feature in Java 21 (LTS)

## Weaknesses

- **No user-defined effects**: Cannot extend the system with custom effect types or handlers
- **Continuations not exposed**: Advanced use cases (generators, coroutines, custom schedulers) cannot be built on top of the continuation primitive
- **Pinning problem**: `synchronized` blocks and native methods prevent virtual thread yielding
- **CPU-bound regression**: Virtual threads can underperform platform threads for compute-intensive work
- **Structured concurrency still in preview**: `StructuredTaskScope` and `ScopedValue` are not yet final features
- **Limited composability**: No mechanism to compose effects or transform handlers like algebraic effect systems provide

## Key Design Decisions and Trade-offs

| Decision                    | Rationale                                                           | Trade-off                                                           |
| --------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Hidden continuations        | Safety; simplicity; avoids exposing error-prone low-level API       | Cannot build generators, coroutines, or custom effect handlers      |
| Virtual threads as `Thread` | Backward compatibility; existing code benefits immediately          | Inherits `Thread` API baggage; no clean break from legacy model     |
| `ForkJoinPool` carriers     | Work-stealing provides good load balancing for I/O workloads        | Suboptimal for CPU-bound work; scheduling latency under contention  |
| Scoped values (immutable)   | Eliminates `ThreadLocal` memory leaks and mutation bugs             | Cannot model mutable state effects; less flexible than full Reader  |
| Structured task scopes      | Prevents thread leaks; clear ownership hierarchy                    | Cannot model unstructured concurrency patterns (fire-and-forget)    |
| No reactive replacement     | Loom complements, not replaces, reactive for backpressure/streaming | Developers must still choose between models for different use cases |

---

## Sources

- [OpenJDK Project Loom](https://openjdk.org/projects/loom/)
- [JEP 444: Virtual Threads](https://openjdk.org/jeps/444)
- [JEP 453: Structured Concurrency (Preview)](https://openjdk.org/jeps/453)
- [JEP 464: Scoped Values (Second Preview)](https://openjdk.org/jeps/464)
- [Project Loom proposal](https://cr.openjdk.org/~rpressler/loom/Loom-Proposal.html) -- Ron Pressler
- [Why Continuations are Coming to Java](https://www.infoq.com/presentations/continuations-java/) -- InfoQ
- [Java Virtual Threads: a Case Study](https://www.infoq.com/articles/java-virtual-threads-a-case-study/) -- InfoQ
- [Beyond Loom: Weaving new concurrency patterns](https://developers.redhat.com/articles/2023/10/03/beyond-loom-weaving-new-concurrency-patterns) -- Red Hat
- [Project Loom: Structured Concurrency in Java](https://rockthejvm.com/articles/structured-concurrency-in-java) -- Rock the JVM
- [Java Scoped Values deep dive](https://www.happycoders.eu/java/scoped-values/) -- HappyCoders
