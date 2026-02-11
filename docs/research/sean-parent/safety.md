# All the Safeties

> "Safety is a hot topic. What do we mean by 'safety'? How does it relate to correctness? What about security?"

## Overview

Sean Parent's "All the Safeties" keynote (C++ on Sea 2023, CppNow 2023) provides a rigorous taxonomy of safety concepts in programming. The talk clarifies the often-conflated terms of safety, correctness, and security, and examines how these concepts apply to C++ specifically.

This is particularly relevant given the industry focus on memory safety and government recommendations about programming language choice.

## Defining Terms

### Safety vs Correctness

**Safety** and **correctness** are often confused but are distinct:

- **Safety**: Nothing bad happens (no undefined behavior, no crashes)
- **Correctness**: The right thing happens (meets specification)

```cpp
// Safe but incorrect
int divide(int a, int b) {
    if (b == 0) return 0;  // Safe (no crash), but wrong answer
    return a / b;
}

// Correct but unsafe (in C++)
int divide(int a, int b) {
    return a / b;  // Correct when b != 0, undefined behavior otherwise
}

// Both safe and correct
std::optional<int> divide(int a, int b) {
    if (b == 0) return std::nullopt;  // Safe
    return a / b;  // Correct
}
```

### Lamport's Definitions

Sean Parent references Leslie Lamport's formal definitions:

- **Safety property**: Nothing bad ever happens
- **Liveness property**: Something good eventually happens

A program must satisfy both to be correct.

## The Safety Taxonomy

### Memory Safety

Prevents invalid memory operations:

| Violation          | Description                 | Example                    |
| ------------------ | --------------------------- | -------------------------- |
| Buffer overflow    | Access beyond bounds        | `arr[n]` where `n >= size` |
| Use-after-free     | Access freed memory         | `delete p; *p = 1;`        |
| Double free        | Free same memory twice      | `delete p; delete p;`      |
| Null dereference   | Access through null pointer | `nullptr->method()`        |
| Uninitialized read | Read before write           | `int x; return x;`         |

```cpp
// Memory unsafe code
void danger() {
    int* p = new int(42);
    delete p;
    *p = 10;  // Use-after-free!
}

// Memory safe alternative
void safe() {
    auto p = std::make_unique<int>(42);
    // p automatically managed
}
```

### Type Safety

Ensures values are used according to their type:

| Violation          | Description                 | Example                    |
| ------------------ | --------------------------- | -------------------------- |
| Type confusion     | Wrong type interpretation   | Casting `int*` to `float*` |
| Union misuse       | Reading wrong union member  | Active member mismatch     |
| Aliasing violation | Incompatible pointer access | Strict aliasing rules      |

```cpp
// Type unsafe
void unsafe() {
    int i = 42;
    float* f = reinterpret_cast<float*>(&i);
    *f = 3.14f;  // Type punning, undefined behavior
}

// Type safe
void safe() {
    int i = 42;
    float f;
    std::memcpy(&f, &i, sizeof(f));  // Defined behavior
}
```

### Thread Safety

Prevents data races and synchronization errors:

| Violation      | Description                      | Example                           |
| -------------- | -------------------------------- | --------------------------------- |
| Data race      | Concurrent unsynchronized access | Two threads writing same variable |
| Race condition | Timing-dependent bug             | Check-then-act patterns           |
| Deadlock       | Circular wait for locks          | Lock ordering violation           |

```cpp
// Thread unsafe
int counter = 0;
void increment() { ++counter; }  // Data race if called from multiple threads

// Thread safe
std::atomic<int> counter{0};
void increment() { ++counter; }  // Atomic operation
```

### Resource Safety

Ensures proper resource management:

| Violation       | Description                 | Example                       |
| --------------- | --------------------------- | ----------------------------- |
| Resource leak   | Failure to release          | Memory, file handles, sockets |
| Use-after-close | Use released resource       | File operations after close   |
| Double release  | Release same resource twice | Double close                  |

```cpp
// Resource unsafe
void unsafe() {
    FILE* f = fopen("file.txt", "r");
    if (error_condition) return;  // Leak!
    fclose(f);
}

// Resource safe (RAII)
void safe() {
    std::ifstream f("file.txt");
    if (error_condition) return;  // Automatically closed
}
```

### Exception Safety

Guarantees about state when exceptions are thrown:

| Level    | Guarantee                            |
| -------- | ------------------------------------ |
| No-throw | Never throws exceptions              |
| Strong   | If exception thrown, state unchanged |
| Basic    | Invariants maintained, no leaks      |
| None     | No guarantees                        |

```cpp
// Strong exception safety (copy-and-swap)
class Container {
public:
    Container& operator=(Container other) {  // Copy made
        swap(*this, other);                   // No-throw swap
        return *this;                         // Old data destroyed
    }
};
```

## The Security Dimension

**Security** differs from safety:

- **Safety**: Protection from accidental misuse
- **Security**: Protection from intentional attack

Memory safety issues often become security vulnerabilities:

| Safety Issue     | Security Exploit                       |
| ---------------- | -------------------------------------- |
| Buffer overflow  | Code injection, ROP attacks            |
| Use-after-free   | Arbitrary code execution               |
| Integer overflow | Buffer size miscalculation             |
| Format string    | Information disclosure, code execution |

## Safety in C++

### Why C++ Is "Unsafe"

C++ provides:

- Direct memory access
- Pointer arithmetic
- Manual memory management
- Type casting
- Undefined behavior by design

This enables performance but creates safety risks.

### Making C++ Safer

#### 1. Modern C++ Features

```cpp
// Use smart pointers
std::unique_ptr<int> p = std::make_unique<int>(42);

// Use containers
std::vector<int> v;
v.at(i);  // Bounds-checked access

// Use string_view instead of char*
void process(std::string_view s);

// Use span for arrays
void process(std::span<int> data);
```

#### 2. Static Analysis

Tools that find safety issues at compile time:

- Clang-Tidy
- PVS-Studio
- Coverity
- SonarQube

#### 3. Runtime Sanitizers

Runtime detection of safety violations:

- AddressSanitizer (ASan) — Memory errors
- UndefinedBehaviorSanitizer (UBSan) — UB detection
- ThreadSanitizer (TSan) — Data races
- MemorySanitizer (MSan) — Uninitialized reads

```bash
# Compile with sanitizers
clang++ -fsanitize=address,undefined -g program.cpp
```

#### 4. Safe Coding Guidelines

- [C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/)
- [SEI CERT C++ Coding Standard](https://wiki.sei.cmu.edu/confluence/display/cplusplus)
- [MISRA C++](https://www.misra.org.uk/)

## Guidelines for Safe Code

### 1. Use RAII Everywhere

```cpp
// BAD: Manual resource management
void bad() {
    int* p = new int(42);
    // ... might throw or return early ...
    delete p;
}

// GOOD: RAII
void good() {
    auto p = std::make_unique<int>(42);
    // Automatically cleaned up
}
```

### 2. Prefer Value Semantics

```cpp
// BAD: Pointer relationships
class Node {
    Node* parent_;
    std::vector<Node*> children_;
};

// GOOD: Value/index relationships
class Tree {
    struct Node {
        size_t parent;
        std::vector<size_t> children;
    };
    std::vector<Node> nodes_;
};
```

### 3. Make Illegal States Unrepresentable

```cpp
// BAD: Can be in invalid state
class Connection {
    Socket socket_;
    bool connected_ = false;
public:
    void send(Data d) {
        if (!connected_) throw ...;  // Runtime check
        socket_.send(d);
    }
};

// GOOD: Type system enforces validity
class DisconnectedConnection { /* ... */ };
class ConnectedConnection {
    Socket socket_;
public:
    void send(Data d) { socket_.send(d); }  // Always valid
};
```

### 4. Use `const` Liberally

```cpp
// Const prevents accidental modification
void process(const std::vector<int>& data) {
    // Can't accidentally modify data
}

// Const member functions
class Widget {
public:
    int getValue() const { return value_; }  // Can't modify state
};
```

### 5. Validate at Boundaries

```cpp
// Validate input at API boundaries
void processUserInput(std::string_view input) {
    if (input.size() > MAX_SIZE) {
        throw std::invalid_argument("Input too large");
    }
    if (!isValidFormat(input)) {
        throw std::invalid_argument("Invalid format");
    }
    // Now safe to process
    processValidated(input);
}
```

## The Industry Context

### Government Recommendations

Recent reports (NSA, CISA, etc.) recommend:

- Using memory-safe languages where possible
- Applying static analysis and sanitizers
- Following secure coding guidelines

### Statistics

Sean Parent cites statistics showing:

- ~70% of Microsoft's CVEs are memory safety issues
- Similar percentages at Google, Apple, Mozilla
- Memory safety is the dominant source of vulnerabilities

### The Path Forward

Options for improving C++ safety:

1. **Profiles** — Subsets of C++ with safety guarantees
2. **Static analysis** — Better tooling
3. **Runtime checks** — Sanitizers, contracts
4. **Language evolution** — Safer defaults, better abstractions
5. **Interop with safe languages** — Rust, etc.

## Summary Table

| Safety Type | What It Prevents                | C++ Tools                            |
| ----------- | ------------------------------- | ------------------------------------ |
| Memory      | Buffer overflow, use-after-free | Smart pointers, containers, ASan     |
| Type        | Type confusion, aliasing        | `std::variant`, `std::any`, concepts |
| Thread      | Data races, deadlocks           | `std::atomic`, `std::mutex`, TSan    |
| Resource    | Leaks, double-free              | RAII, smart pointers                 |
| Exception   | Inconsistent state              | Strong guarantee patterns            |

## References

### Primary Sources

- **[All the Safeties (C++ on Sea 2023)](https://www.youtube.com/watch?v=BaUv9sgLCPc)** — Keynote video
- **[All the Safeties (CppNow 2023)](https://www.youtube.com/watch?v=MO-qehjc04s)** — Earlier version
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2023-06-28-all-the-safeties/2023-06-28-all-the-safeties.pdf)**

### Related Material

- **[Safety, Revisited](https://isocpp.org/blog/2024/03/safety-revisited-lucian-radu-teodorescu)** — Follow-up article
- **[C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/)** — Safe coding guidelines

---

_"Safety is not optional. It's not a feature. It's a requirement."_ — Sean Parent
