# Local Reasoning

> "Local reasoning is the ability to look at a defined unit of code—a function or a class—understand it, and verify its correctness without understanding all the contexts within which it is used."

## Overview

> "Complexity is anything that prevents local reasoning." — Sean Parent

Local reasoning is perhaps the most fundamental principle in Sean Parent's philosophy of software development. It addresses the core challenge of managing complexity: how can we understand and verify code when systems grow too large for any single person to hold in their head?

Sean Parent argues that **global reasoning does not scale**. While we can reason globally about a small system (e.g., 10 functions), our capacity for global understanding is quickly exceeded as systems grow. Local reasoning allows us to build large, complex systems that remain understandable by ensuring that each component can be verified in isolation.

This principle is grounded in how we build physical systems—a circuit designer doesn't need to understand the entire computer to verify a single logic gate.

## Why Local Reasoning Matters

### The Scalability Problem

As codebases grow, understanding becomes exponentially harder:

- **10 functions**: Easy to hold in your head (Global Reasoning works)
- **100 functions**: Need documentation and conventions
- **10,000 functions**: Must be able to reason locally
- **1,000,000 functions**: Local reasoning is the only way

### The Three Ways to Achieve Independence

To reason locally, a unit of code must be independent of its context. Sean Parent identifies three strategies to achieve this:

1.  **No Mutation (Functional)**: If data never changes, we don't need to worry about who else might be looking at it.
2.  **No Sharing (Value Semantics)**: If we have our own copy of the data, we can mutate it without affecting anyone else.
3.  **No Mutation of Shared Objects (Exclusivity)**: If we must share and mutate, we must ensure **exclusive access**. This is the "Law of Exclusivity."

### Benefits of Local Reasoning

1. **Understandability** — Code is readable by others and your future self
2. **Maintainability** — Changes don't cause unexpected side effects elsewhere
3. **Testability** — Units with clear contracts are easy to test in isolation
4. **Parallelization** — Team members can work independently
5. **Verification** — Correctness can be checked piece by piece

## Core Principles

### 1. Specification Comes First

Every unit of code should have a clear specification:

- **What it does** — The transformation or effect
- **Preconditions** — What must be true before calling
- **Postconditions** — What will be true after calling
- **Invariants** — What remains true throughout

```cpp
/// Increments the value of x by 1
/// @pre No other thread is accessing x
/// @post x == old(x) + 1
void increment(int& x) {
    ++x;
}
```

### 2. Separate Client and Implementor Perspectives

When designing an API, consider two viewpoints:

**Client (Caller)**:

- What do I need to provide?
- What can I expect in return?
- What must I not do?

**Implementor (Callee)**:

- What can I assume about inputs?
- What must I guarantee about outputs?
- What am I allowed to do with the arguments?

The specification is the contract between them.

### 3. Minimize Implicit Dependencies

Hidden dependencies destroy local reasoning. This includes global state, but also **aliasing**.

**The Law of Exclusivity**:
If you have a mutable reference to a value, you should have no other references to that value. While languages like Rust and Swift enforce this, in C++ it must be managed via convention.

```cpp
// BAD: Hidden dependency on global state
int compute() {
    return global_config.value * 2;  // What is global_config?
}

// GOOD: Explicit dependency
int compute(int value) {
    return value * 2;
}

// BAD: Hidden mutation via aliasing
void process(std::vector<int>& v, const std::vector<int>& other) {
    // If &v == &other, modifying v changes other!
    v.push_back(1);
    // ...
}
```

### 4. Parameter Passing Conventions

Clear conventions for how arguments are passed allow us to assume the "Law of Exclusivity" is upheld:

| Convention           | Syntax           | Meaning                                        |
| -------------------- | ---------------- | ---------------------------------------------- |
| Input (read-only)    | `const T&`       | Caller retains ownership, callee only reads    |
| Input (sink/consume) | `T` or `T&&`     | Callee takes ownership                         |
| In-out (modify)      | `T&`             | Caller retains ownership, callee may modify    |
| Output               | `T&` (out param) | Callee writes, typically should return instead |

**Preconditions for Reasoning**:

- **Non-const references**: Must not be accessed by other threads or via other aliases during the call.
- **Const references**: Must not be written to by other threads during the call.
- **Lifetimes**: Referenced objects must remain valid for the duration of the call.

### 5. Concurrency Rules

Concurrency is the ultimate test of local reasoning. Shared mutable state across threads creates implicit preconditions that are often invisible and uncheckable.

```cpp
/// Increments the counter
/// @pre No other thread may access `counter` during this call
void increment(int& counter) {
    ++counter;
}

/// Thread-safe increment
/// @note May be called from multiple threads simultaneously
void increment(std::atomic<int>& counter) {
    ++counter;
}
```

### 6. Transformations vs Actions

Sean Parent defines a specific duality between transformations and actions:

- **Transformation**: A function `f: T -> T` (or `f: (T, ...) -> T`). It takes a value and returns a new value of the same type. These are pure and support **equational reasoning** (you can replace the call with its result).
- **Action**: The application of a transformation to the state of an object.

```cpp
// Transformation: pure, easy to reason about
int square(int x) {
    return x * x;
}

// Action: modifies state by applying a transformation
void update_square(int& x) {
    x = square(x);
}
```

By separating the "what" (transformation) from the "where" (action/state update), we isolate the complex logic into pure functions that are trivial to reason about locally.

## Guidelines for Local Reasoning

### Guideline 1: Document Specifications

Every public function should have a specification:

```cpp
/// Searches for value in the sorted range [first, last)
///
/// @param first  Iterator to the beginning of the range
/// @param last   Iterator past the end of the range
/// @param value  Value to search for
///
/// @pre [first, last) is sorted according to operator<
/// @pre No concurrent modification of the range
///
/// @return Iterator to the first element not less than value,
///         or last if no such element exists
///
/// @complexity O(log(last - first)) comparisons
template<typename It, typename T>
It lower_bound(It first, It last, const T& value);
```

### Guideline 2: Keep Functions Focused

A function should do one thing well:

```cpp
// BAD: Does too many things
void processAndSaveAndNotify(Data& data) {
    validate(data);
    transform(data);
    save(data);
    notifyObservers(data);
}

// GOOD: Single responsibility, composed
void handleData(Data& data) {
    validate(data);
    transform(data);
}

void persistData(const Data& data) {
    save(data);
    notifyObservers(data);
}
```

### Guideline 3: Avoid Out Parameters

Return values are clearer than out parameters:

```cpp
// BAD: Out parameter
bool tryParse(const std::string& s, int& result);

// GOOD: Return optional
std::optional<int> tryParse(const std::string& s);

// BAD: Multiple out parameters
void compute(int x, int& sum, int& product);

// GOOD: Return a struct
struct ComputeResult { int sum; int product; };
ComputeResult compute(int x);
```

### Guideline 4: Make Preconditions Checkable

Preconditions should be verifiable (at least in debug mode):

```cpp
void processPositive(int x) {
    assert(x > 0 && "x must be positive");  // Checkable precondition
    // ...
}

// Even better with contracts (C++20/23)
void processPositive(int x)
    [[expects: x > 0]]
{
    // ...
}
```

### Guideline 5: Limit Scope of Mutable State

Keep mutable state as local as possible:

```cpp
// BAD: Class-level mutable state
class Processor {
    std::vector<int> buffer_;  // Persistent mutable state
public:
    void process(const Data& d) {
        buffer_.clear();
        // ... use buffer_ ...
    }
};

// GOOD: Function-local state
class Processor {
public:
    void process(const Data& d) {
        std::vector<int> buffer;  // Local to this call
        // ... use buffer ...
    }
};
```

### Guideline 6: Prefer Immutability

Immutable data supports local reasoning automatically:

```cpp
// Mutable: must track all modifications
void process(std::vector<int>& v) {
    step1(v);  // Did this modify v?
    step2(v);  // What state is v in now?
    step3(v);  // Hard to reason about
}

// Immutable: transformations are clear
std::vector<int> process(std::vector<int> v) {
    auto v1 = step1(std::move(v));
    auto v2 = step2(std::move(v1));
    return step3(std::move(v2));
}
```

### Guideline 7: Explicitly Model Relationships

Local reasoning is often broken by "hidden" relationships between objects (e.g., pointers that create a graph where the client only sees a tree).

- **Prefer Trees over Graphs**: Hierarchical ownership is much easier to reason about locally.
- **Explicit Links**: If two objects must know about each other, make that relationship part of the model and the specification.
- **Avoid "Spooky Action at a Distance"**: Changes to object A should not unexpectedly affect object B unless there is an explicit, documented relationship.

### Safety vs. Correctness

A critical distinction in Sean Parent's work:

- **Safety composes**: If you build a system out of safe components (e.g., memory-safe), the resulting system is also safe.
- **Correctness does NOT compose**: You can build a system out of "correct" components, but the whole system may be incorrect if the local reasoning about how they interact is flawed.

Local reasoning is the tool we use to ensure that when we compose components, the resulting system's correctness can still be verified.

## Common Violations of Local Reasoning

### Global State

```cpp
// Global state destroys local reasoning
int globalCounter = 0;

void increment() {
    ++globalCounter;  // Who else might modify this?
}
```

### Hidden Aliasing

```cpp
void process(int& a, int& b) {
    a = 1;
    b = 2;
    // Is a still 1? Only if a and b don't alias!
}

int x = 0;
process(x, x);  // Surprise! x == 2
```

### Callbacks and Observers

```cpp
class Subject {
    std::vector<Observer*> observers_;
public:
    void notify() {
        for (auto* o : observers_) {
            o->update();  // What does this do? Could modify anything!
        }
    }
};
```

### Thread-Unsafe Assumptions

```cpp
void unsafeIncrement(int& x) {
    int temp = x;
    ++temp;
    x = temp;  // Data race if x is shared!
}
```

## Testing Local Reasoning

Code that supports local reasoning is easy to test:

```cpp
// Easy to test: pure function
TEST(Square, ReturnsSquareOfInput) {
    EXPECT_EQ(square(0), 0);
    EXPECT_EQ(square(2), 4);
    EXPECT_EQ(square(-3), 9);
}

// Easy to test: clear preconditions and postconditions
TEST(Sort, SortsVector) {
    std::vector<int> v = {3, 1, 4, 1, 5};
    sort(v);
    EXPECT_TRUE(std::is_sorted(v.begin(), v.end()));
}

// Hard to test: depends on global state
TEST(GlobalCounter, Increment) {
    globalCounter = 0;  // Must set up global state
    increment();
    EXPECT_EQ(globalCounter, 1);  // Fragile if other tests run
}
```

## References

### Primary Sources

- **[Local Reasoning in C++ (NDC TechTown 2024)](https://www.youtube.com/watch?v=bhizxAXQlWc)** — Most comprehensive presentation
- **[Local Reasoning Slides (PDF)](https://sean-parent.stlab.cc/presentations/2024-09-12-local-reasoning/2024-09-12-local-reasoning.pdf)** — Presentation slides
- **[Local Reasoning Slides with Notes](https://sean-parent.stlab.cc/presentations/2024-09-12-local-reasoning/2024-09-12-local-reasoning-notes.pdf)** — Annotated version

### Related Papers

- **[Local Reasoning Can Help Prove Correctness](https://accu.org/journals/overload/33/188/teodorescu-parent/)** — Paper by Lucian Radu Teodorescu and Sean Parent

### Related Talks

- **Better Code: Contracts** — Formal specification of behavior
- **All the Safeties** — Safety properties that support local reasoning

---

_"The key to making programs that work is to make programs that are locally correct—programs where you can look at each piece and understand why it works."_ — Sean Parent
