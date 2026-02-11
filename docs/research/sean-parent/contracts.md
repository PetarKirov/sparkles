# Better Code: Contracts

> "Are you confident that the code you write and your changes are correct? What does 'correct' even mean?"

## Overview

"Better Code: Contracts" is a talk co-authored and presented by Sean Parent and Dave Abrahams at CppCon 2023. It explores how contracts—preconditions, postconditions, and invariants—form the "connective tissue" of good code and provide a foundation for reasoning about correctness.

The key insight is that explicit contracts enable local reasoning, replace code reviews with something better, and chart a path toward provably correct software.

## What Is a Contract?

A contract is a formal specification of:

1. **Preconditions**: What must be true before a function is called
2. **Postconditions**: What will be true after a function returns
3. **Invariants**: What is always true about a type or system

```cpp
/// Divides a by b
/// @pre b != 0
/// @post result * b == a (for exact division)
int divide(int a, int b) {
    assert(b != 0);  // Precondition check
    return a / b;
}
```

## Why Contracts Matter

### 1. Define Correctness

Without a specification, "correct" has no meaning:

```cpp
// What does this function do?
int mystery(int x);

// With contract, correctness is defined:
/// Returns the square root of x, rounded down
/// @pre x >= 0
/// @post result * result <= x
/// @post (result + 1) * (result + 1) > x
int isqrt(int x);
```

### 2. Enable Local Reasoning

Contracts let you understand code in isolation:

```cpp
// Can I pass a negative number? Check preconditions.
// What can I expect back? Check postconditions.
// Don't need to read implementation.
```

### 3. Document Intent

Contracts are executable documentation:

```cpp
/// Sorts the range [first, last) in ascending order
/// @pre [first, last) is a valid range
/// @post std::is_sorted(first, last)
/// @post The range contains the same elements (permutation)
template<typename It>
void sort(It first, It last);
```

### 4. Enable Verification

Contracts can be checked:

- At runtime (assertions)
- At compile time (static analysis)
- Formally (mathematical proof)

## Preconditions

Preconditions specify what the caller must guarantee:

### Writing Preconditions

```cpp
/// Pops an element from the stack
/// @pre !empty()
void Stack::pop() {
    assert(!empty());  // Debug check
    --size_;
}

/// Returns element at index i
/// @pre i < size()
T& Vector::operator[](size_t i) {
    assert(i < size());
    return data_[i];
}

/// Copies n bytes from src to dst
/// @pre src != nullptr
/// @pre dst != nullptr
/// @pre [src, src + n) and [dst, dst + n) don't overlap
void copy(const void* src, void* dst, size_t n);
```

### Precondition Guidelines

1. **Be specific**: State exactly what's required
2. **Be minimal**: Don't require more than necessary
3. **Be checkable**: Preconditions should be verifiable
4. **Document threading**: State concurrency requirements

```cpp
/// Increments the counter
/// @pre No other thread is accessing counter during this call
void increment(int& counter);
```

## Postconditions

Postconditions specify what the function guarantees:

### Writing Postconditions

```cpp
/// Allocates memory
/// @post result != nullptr OR throws std::bad_alloc
/// @post result is aligned to alignof(std::max_align_t)
void* allocate(size_t n);

/// Sorts in place
/// @post std::is_sorted(begin(), end())
void Vector::sort();

/// Returns the maximum element
/// @pre !empty()
/// @post result >= all other elements
/// @post result is in the range
T& Vector::max();
```

### Postcondition Guidelines

1. **Describe the effect**: What changed?
2. **Describe the return value**: What does it represent?
3. **Describe side effects**: What else happened?
4. **Include failure modes**: What if it fails?

## Invariants

Invariants are conditions that are always true:

### Class Invariants

```cpp
class SortedVector {
    std::vector<int> data_;

    // Class invariant: data_ is always sorted
    // All public operations maintain this invariant

public:
    void insert(int value) {
        auto pos = std::lower_bound(data_.begin(), data_.end(), value);
        data_.insert(pos, value);
        // Invariant maintained
    }

    void remove(int value) {
        auto pos = std::lower_bound(data_.begin(), data_.end(), value);
        if (pos != data_.end() && *pos == value) {
            data_.erase(pos);
        }
        // Invariant maintained
    }
};
```

### Loop Invariants

```cpp
int binarySearch(const int* arr, int n, int target) {
    int lo = 0, hi = n;

    // Loop invariant: If target exists, it's in [lo, hi)
    while (lo < hi) {
        int mid = lo + (hi - lo) / 2;

        if (arr[mid] < target) {
            lo = mid + 1;
            // Invariant: target not in [0, lo), still in [lo, hi)
        } else {
            hi = mid;
            // Invariant: target not in [hi, n), still in [lo, hi)
        }
    }

    // Loop ended: lo == hi, range is empty
    // If target existed, it would be at lo
    return (lo < n && arr[lo] == target) ? lo : -1;
}
```

## Expressing Contracts

### Documentation (Current Practice)

```cpp
/// @brief Finds the first occurrence of value in range
/// @param first Iterator to the beginning of the range
/// @param last Iterator past the end of the range
/// @param value Value to search for
/// @pre [first, last) is a valid range
/// @return Iterator to the element, or last if not found
/// @post If returned iterator i != last, then *i == value
/// @complexity O(last - first)
template<typename It, typename T>
It find(It first, It last, const T& value);
```

### Assertions (Runtime Check)

```cpp
#include <cassert>

void processPositive(int x) {
    assert(x > 0 && "x must be positive");
    // ...
}
```

### C++20 Contracts (Proposed)

```cpp
// Note: Not yet in standard, but proposed
int divide(int a, int b)
    [[expects: b != 0]]           // Precondition
    [[ensures r: r * b == a]]      // Postcondition
{
    return a / b;
}

class Stack {
public:
    void push(int x)
        [[ensures: !empty()]]
        [[ensures: top() == x]];

    void pop()
        [[expects: !empty()]];
};
```

### GSL Expects/Ensures

```cpp
#include <gsl/gsl>

void process(gsl::span<int> data) {
    Expects(!data.empty());  // Precondition

    // Process data...

    Ensures(isValid(data));  // Postcondition
}
```

## Contract-Based Design

### Design by Contract Methodology

1. **Write contract first**: Specify before implementing
2. **Implement to contract**: Code fulfills the specification
3. **Test against contract**: Verify contract is met
4. **Document with contract**: Specification is the documentation

### Example: Designing a Stack

```cpp
/// A stack of integers
///
/// Invariant: size() <= capacity()
/// Invariant: Elements are stored in LIFO order
class Stack {
public:
    /// Constructs an empty stack
    /// @post empty()
    /// @post size() == 0
    Stack();

    /// Returns true if stack is empty
    /// @post result == (size() == 0)
    bool empty() const;

    /// Returns number of elements
    /// @post result >= 0
    size_t size() const;

    /// Adds element to top
    /// @post !empty()
    /// @post size() == old size() + 1
    /// @post top() == x
    void push(int x);

    /// Removes top element
    /// @pre !empty()
    /// @post size() == old size() - 1
    void pop();

    /// Returns top element
    /// @pre !empty()
    /// @post result == most recently pushed element not yet popped
    int top() const;
};
```

## Contracts and Testing

### Contracts Replace Some Tests

```cpp
// Without contracts: test many cases
TEST(Divide, Zero) { EXPECT_THROW(divide(1, 0), ...); }
TEST(Divide, Positive) { EXPECT_EQ(divide(6, 2), 3); }
TEST(Divide, Negative) { EXPECT_EQ(divide(-6, 2), -3); }
// etc.

// With contracts: test contract itself
TEST(Divide, SatisfiesPostcondition) {
    for (int a = -100; a <= 100; ++a) {
        for (int b = -100; b <= 100; ++b) {
            if (b != 0) {  // Precondition
                int r = divide(a, b);
                EXPECT_EQ(r * b, a);  // Postcondition
            }
        }
    }
}
```

### Property-Based Testing

```cpp
// Generate random inputs that satisfy preconditions
// Verify postconditions hold
void testSort() {
    for (int trial = 0; trial < 1000; ++trial) {
        auto v = generateRandomVector();  // Any vector (precondition: none)

        sort(v.begin(), v.end());

        // Check postconditions
        ASSERT_TRUE(std::is_sorted(v.begin(), v.end()));
        // Could also check it's a permutation of original
    }
}
```

## Guidelines

### 1. Make Contracts Explicit

```cpp
// BAD: Implicit contract
void process(int* data, int size);

// GOOD: Explicit contract
/// @pre data != nullptr
/// @pre size > 0
/// @pre [data, data + size) is valid
void process(int* data, int size);
```

### 2. Check Preconditions in Debug

```cpp
void pop() {
    assert(!empty() && "Cannot pop from empty stack");  // Debug check
    --size_;
}
```

### 3. Document What You Can't Check

```cpp
/// @pre No other thread accesses data during this call
/// (Cannot check at runtime, but document it)
void process(Data& data);
```

### 4. Keep Invariants Simple

```cpp
// Complex invariant - hard to maintain
class Complex {
    // Invariant: a*a + b*b == c*c && gcd(a,b,c) == 1 && ...
};

// Simple invariant - easy to maintain
class Point {
    double x_, y_;
    // Invariant: none (any double values valid)
};
```

### 5. Strengthen Gradually

```cpp
// Start with weak contract
void process(int x);

// Strengthen as understanding grows
/// @pre x >= 0
void process(int x);

// Further strengthen
/// @pre x >= 0
/// @pre x < 1000
void process(int x);
```

## References

### Primary Sources

- **[Better Code: Contracts (YouTube)](https://www.youtube.com/watch?v=OWsepDEh5lQ)** — CppCon 2023
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2023-10-06-better-code-contracts/2023-10-06-better-code-contracts.pdf)**

### Related Material

- **Local Reasoning in C++** — Contracts support local reasoning
- **[GSL Guidelines Support Library](https://github.com/microsoft/GSL)** — Expects/Ensures macros
- **[C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/)** — Contract recommendations

### Further Reading

- Meyer, Bertrand. "Object-Oriented Software Construction" — Design by Contract
- Liskov, Barbara. "Data Abstraction and Hierarchy" — Behavioral subtyping

---

_"A contract is not just documentation—it's a specification that enables reasoning, testing, and verification."_ — Sean Parent & Dave Abrahams
