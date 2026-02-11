# Local Reasoning

> "Local reasoning is the ability to look at a defined unit of code—a function or a class—understand it, and verify its correctness without understanding all the contexts within which it is used."

## Overview

Local reasoning is perhaps the most fundamental principle in Sean Parent's philosophy of software development. It addresses the core challenge of managing complexity: how can we understand and verify code when systems grow too large for any single person to hold in their head?

The answer is to structure code so that each piece can be understood independently, without needing to trace through the entire codebase.

## Why Local Reasoning Matters

### The Scalability Problem

As codebases grow, understanding becomes exponentially harder:

- **10 functions**: Easy to hold in your head
- **100 functions**: Need documentation and conventions
- **10,000 functions**: Must be able to reason locally
- **1,000,000 functions**: Local reasoning is the only way

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

Hidden dependencies destroy local reasoning:

```cpp
// BAD: Hidden dependency on global state
int compute() {
    return global_config.value * 2;  // What is global_config?
}

// GOOD: Explicit dependency
int compute(int value) {
    return value * 2;
}

// BAD: Hidden mutation
void process(std::vector<int>& v) {
    other_function();  // Does this affect v?
    // ...
}

// GOOD: Clear that nothing else touches v
void process(std::vector<int>& v) {
    // Only this function accesses v during this call
    for (auto& x : v) x *= 2;
}
```

### 4. Parameter Passing Conventions

Clear conventions for how arguments are passed:

| Convention           | Syntax           | Meaning                                        |
| -------------------- | ---------------- | ---------------------------------------------- |
| Input (read-only)    | `const T&`       | Caller retains ownership, callee only reads    |
| Input (sink/consume) | `T` or `T&&`     | Callee takes ownership                         |
| In-out (modify)      | `T&`             | Caller retains ownership, callee may modify    |
| Output               | `T&` (out param) | Callee writes, typically should return instead |

```cpp
// Input: read-only access
void print(const std::string& s);

// Sink: takes ownership
void store(std::string name);  // Pass by value, will be moved into

// In-out: modifies the argument
void sort(std::vector<int>& v);

// Output: prefer return value
std::vector<int> compute();  // Better than out parameter
```

### 5. Concurrency Rules

Explicitly state threading assumptions:

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

Distinguish between:

- **Transformations** (pure functions): Take inputs, produce outputs, no side effects
- **Actions** (procedures): May modify state, have side effects

```cpp
// Transformation: pure, easy to reason about
int square(int x) {
    return x * x;
}

// Action: has side effects, document clearly
/// Writes data to the file
/// @pre file is open for writing
/// @post data is written, file position advanced
void write(File& file, std::span<const std::byte> data);
```

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
