# Better Code: Contracts

> "Are you confident that the code you write and your changes are correct? What does 'correct' even mean?"

## Overview

"Better Code: Contracts" is a philosophy and set of practices co-authored and presented by Sean Parent and Dave Abrahams (notably at CppCon 2023). It explores how contracts—preconditions, postconditions, and invariants—form the "connective tissue" of good code and provide the essential foundation for **local reasoning**.

The key insight is that explicit contracts define what "correct" means for a piece of code, allowing us to move beyond brittle processes like manual code review toward provably correct software and automated verification.

## The Problem: "Code Review is a Failed Process"

Sean Parent argues that traditional code review is an insufficient and failed process for ensuring software quality.

- **Subjective**: It relies on the reviewer's intuition and knowledge at a specific moment.
- **Incomplete**: It cannot catch all logical errors or edge cases.
- **Scaling**: As systems grow, it becomes impossible for any human to hold the entire context in their head.

**The Solution**: Replace code review with **contracts** and **automated verification** (like property-based testing). A contract is a formal, machine-verifiable specification of behavior.

## What Is a Contract?

A contract is a formal specification of:

1. **Preconditions** (Hoare: $\{P\}$): What must be true before a function is called.
2. **Postconditions** (Hoare: $\{Q\}$): What will be true after a function returns.
3. **Invariants**: What is always true about a type or system (except during internal mutation).

These form a **Hoare Triple**: $\{P\} S \{Q\}$, where $S$ is the statement/execution.

```cpp
/// Returns the square root of x, rounded down
/// @pre x >= 0
/// @post result * result <= x
/// @post (result + 1) * (result + 1) > x
int isqrt(int x) {
    assert(x >= 0); // Contract check (Precondition)
    int result = std::sqrt(x);
    // Postconditions can be checked in debug or verified formally
    return result;
}
```

## Narrow vs. Wide Contracts

One of the most important distinctions in Sean Parent's guidance:

- **Narrow Contract**: Has preconditions (e.g., `vector::operator[]`). If preconditions are violated, behavior is undefined (a bug). Narrow contracts are often more efficient because they don't perform redundant checks.
- **Wide Contract**: Has no preconditions (e.g., `vector::at`). It handles all possible inputs, typically by throwing an exception for "invalid" values.

```cpp
// NARROW CONTRACT: Fast, assumes caller is correct.
// Responsibility: Caller must ensure i < size()
T& operator[](size_t i) {
    assert(i < size());
    return data_[i];
}

// WIDE CONTRACT: Safe, handles all inputs.
// Responsibility: Callee handles invalid input.
T& at(size_t i) {
    if (i >= size()) throw std::out_of_range("...");
    return data_[i];
}
```

**Parent's Guidance**: Prefer **narrow contracts** for internal logic. They clarify responsibility and enable local reasoning. If a precondition is violated, it's a bug in the _caller_, not the _callee_.

## Contract Checking vs. Input Validation

A critical point of confusion that Sean clarifies:

- **Input Validation**: Processes untrusted, external data (user input, network packets). This is _runtime logic_ that must handle errors gracefully.
- **Contract Checking**: Verifies the internal consistency of a defect-free program. These are _assertions_ that should never be triggered in a correct program. They are typically removed in production builds for performance.

```cpp
void process_user_request(JSON data) {
    // 1. INPUT VALIDATION (Runtime feature)
    if (!data.contains("id")) {
        log_error("Invalid request");
        return;
    }

    // 2. CALL INTERNAL LOGIC (Contracted)
    internal_process(data["id"].as_int());
}

/// @pre id > 0
void internal_process(int id) {
    // 3. CONTRACT CHECK (Debug assertion)
    assert(id > 0 && "Contract violation: id must be positive");
    // ... logic ...
}
```

> "A contract violation is a bug. Input validation is a feature."

## Why Contracts Matter

### 1. Enable Local Reasoning

Local reasoning is the ability to understand a function or class by looking only at its definition and the definitions of things it calls. Contracts provide the boundaries that make this possible.

### 2. Define Correctness

Without a specification, "correct" has no meaning. A function isn't "broken" if it doesn't do what you _thought_ it would do; it's broken if it violates its contract.

### 3. Replace Defensive Programming

Defensive programming (checking everything everywhere) leads to "check-bloat" and performance degradation. Contracts assign responsibility: the caller guarantees preconditions, the callee guarantees postconditions.

### 4. Semantic Axioms and Regular Types

Contracts extend to the **axioms** of a type. For example, a **Regular Type** has an "Axiom of Copy": after `T a = b;`, the contract is that `a == b` and `a` is a disjoint copy (modifying `a` does not affect `b`).

## Preconditions

Preconditions specify the obligations of the **caller**.

### Writing Preconditions

```cpp
/// Pops an element from the stack
/// @pre !empty()
void Stack::pop() {
    assert(!empty());
    --size_;
}

/// Copies n bytes
/// @pre src != nullptr && dst != nullptr
/// @pre [src, src + n) and [dst, dst + n) don't overlap
void copy(const void* src, void* dst, size_t n);
```

### Guidelines

1. **Be specific and minimal**: Don't require more than necessary.
2. **Checkable**: Preconditions should ideally be $O(1)$ or $O(\text{operation})$.
3. **Complexity Requirements**: Performance characteristics (e.g., "must be $O(1)$") are part of the contract.

## Postconditions

Postconditions specify the guarantees of the **callee**.

### Writing Postconditions

```cpp
/// Allocates memory
/// @post result != nullptr OR throws std::bad_alloc
/// @post result is aligned to alignof(std::max_align_t)
void* allocate(size_t n);

/// Sorts in place
/// @post std::is_sorted(begin(), end())
/// @post is_permutation(original_range, new_range)
void sort(Iterator first, Iterator last);
```

### Guidelines

1. **Describe the effect**: What changed?
2. **Describe the return value**: What does it represent?
3. **Exception Guarantees**: State which exception guarantee is provided (No-throw, Strong, or Basic).

## Invariants

Invariants are properties that must hold true for the lifetime of an object.

### Class Invariants

```cpp
class SortedVector {
    std::vector<int> data_;

    // Invariant: data_ is always sorted
    // Invariant: data_.size() <= data_.capacity()

public:
    void insert(int value) {
        // Invariant holds on entry
        auto pos = std::lower_bound(data_.begin(), data_.end(), value);
        data_.insert(pos, value);
        // Invariant restored on exit
    }
};
```

### Mutating Operations and Invariants

Invariants can be **temporarily broken** during a mutating operation.

- **The Rule**: Invariants must be restored before control returns to the caller.
- **Basic Guarantee**: Even if an operation fails, the object must be left in a valid state (invariants held), even if its value is indeterminate.

## Contracts and Testing

### Property-Based Testing

Instead of writing hundreds of manual test cases, write a generator that produces inputs satisfying the **preconditions** and a test that verifies the **postconditions** and **invariants** hold.

```cpp
// Property-based test for sort()
void test_sort_contract() {
    for (auto trial : range(1000)) {
        auto v = generate_random_vector(); // Precondition: none
        auto original = v;

        sort(v.begin(), v.end());

        // Verify Postconditions
        assert(std::is_sorted(v.begin(), v.end()));
        assert(std::is_permutation(v.begin(), v.end(), original.begin()));
    }
}
```

## Summary Guidelines

1. **Make Contracts Explicit**: Don't rely on "tribal knowledge."
2. **Prefer Narrow Contracts**: Assign responsibility clearly.
3. **Use Assertions for Contracts**: Use them to catch bugs during development.
4. **Distinguish from Error Handling**: Contracts are for programmers; error handling is for users.
5. **Complexity is a Contract**: If a function becomes $O(N^2)$ instead of $O(N)$, it has violated its contract.

## References

### Primary Sources

- **[Better Code: Contracts (YouTube)](https://www.youtube.com/watch?v=OWsepDEh5lQ)** — CppCon 2023
- **[Better Code: Data Structures (YouTube)](https://www.youtube.com/watch?v=sWgDk-o-6ZE)** — Discusses invariants and axioms.
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2023-10-06-better-code-contracts/2023-10-06-better-code-contracts.pdf)**

### Related Material

- **Hoare, C. A. R.** (1969). "An axiomatic basis for computer programming."
- **Stepanov, Alexander.** "Notes on Programming" — The basis for Regular Types and axioms.

---

_"A contract is the formal expression of our intent, enabling us to reason about our code as a mathematical system rather than a collection of instructions."_
