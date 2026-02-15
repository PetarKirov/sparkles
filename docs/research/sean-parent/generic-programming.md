# Generic Programming

> "Generic programming is the definition of algorithms and data structures at an abstract or generic level, thereby accomplishing many related programming tasks simultaneously." — Alexander Stepanov and David Musser (1988)

## Overview

Sean Parent's "Generic Programming" talk (code::dive 2018, pacific++ 2018) traces the history and principles of generic programming from its origins with Alexander Stepanov through its impact on C++ and modern software development.

The talk emphasizes that generic programming is not merely "templates" or a "paradigm," but a fundamental approach to software construction based on the idea that **mathematics is discovery, not invention**. Consequently, writing software is the process of discovering the underlying algebraic structures and quantitative laws that govern a problem.

## Core Philosophy

### Discovery vs. Invention

Parent (following Stepanov) argues that we don't "invent" algorithms; we discover them. Just as Euler discovered mathematical truths, programmers discover the most efficient and general way to perform a task.

### Discovery Example: Egyptian Multiplication

Parent often uses "Egyptian Multiplication" (or the Russian Peasant algorithm) to show how an efficient algorithm for one problem (multiplication) is actually a generic algorithm for any operation that is associative (like exponentiation).

- **Concrete:** `n * x` can be computed by doubling and adding.
- **Generic:** The same "template" computes `x^n` by squaring and multiplying.
- **Discovery:** We discovered a general power algorithm, of which multiplication is just one model (where the operation is addition).

## Historical Context

### 1977: John Backus and the von Neumann Critique

In his Turing Award lecture, Backus critiqued the "word-at-a-time" style of von Neumann programming. He proposed a functional style using "combining forms" (higher-order functions) to build complex programs from simple ones, a precursor to algorithm composition in GP.

### 1979: Ken Iverson and Notation

Ken Iverson (creator of APL) emphasized "Notation as a Tool of Thought." He showed that a precise mathematical notation allows for higher-level reasoning about data transformations.

### 1981: Tecton

D. Kapur, D.R. Musser, and Alexander Stepanov introduced **Tecton**, a language for manipulating generic objects. This was the first formal attempt to build a system based on generic principles.

### 1988: Origins of GP

Stepanov and Musser officially coined "generic programming" while working on libraries for Ada and later C++. Stepanov's key insight:

> "Algorithms are more fundamental than the data structures on which they operate."

### The STL

The Standard Template Library, designed by Stepanov and implemented with Meng Lee, demonstrated that:

- Generic algorithms can be as efficient as hand-written code
- Abstract concepts (iterators) can bridge algorithms and containers
- Template metaprogramming enables compile-time optimization

### Elements of Programming

Stepanov and Paul McJones's book "Elements of Programming" provides the mathematical foundation:

- Regular types
- Concepts and axioms
- Algorithm requirements
- Complexity guarantees

### Associativity and Parallelism

One of Parent's key examples of a "discovered" mathematical property in GP is **associativity**.

- If an operation is associative: `(a ∙ b) ∙ c = a ∙ (b ∙ c)`
- Then the operation can be performed in parallel (parallel reduction).
- This links software directly to the algebraic structure of a **Monoid**.

## Core Concepts

### Iterators

Iterators are the bridge between algorithms and data structures:

```cpp
// Iterator categories
// Input: single-pass forward reading
// Output: single-pass forward writing
// Forward: multi-pass forward
// Bidirectional: forward and backward
// RandomAccess: arbitrary access

template<typename InputIt, typename T>
InputIt find(InputIt first, InputIt last, const T& value) {
    for (; first != last; ++first) {
        if (*first == value) return first;
    }
    return last;
}
```

### Concepts

Concepts define the requirements on types:

```cpp
// C++20 Concepts
template<typename T>
concept Regular = std::copyable<T> &&
                  std::default_initializable<T> &&
                  std::equality_comparable<T>;

template<typename I>
concept RandomAccessIterator =
    std::bidirectional_iterator<I> &&
    std::totally_ordered<I> &&
    requires(I i, I j, std::iter_difference_t<I> n) {
        { i + n } -> std::same_as<I>;
        { i - n } -> std::same_as<I>;
        { i - j } -> std::same_as<std::iter_difference_t<I>>;
        { i[n] } -> std::same_as<std::iter_reference_t<I>>;
    };
```

### Axioms

Concepts have semantic requirements (axioms) beyond syntax:

```cpp
// Equality must be:
// - Reflexive: a == a
// - Symmetric: a == b implies b == a
// - Transitive: a == b and b == c implies a == c

// Iterators must satisfy:
// - ++i makes progress
// - *i returns the referenced value
// - i == j implies *i == *j
```

## Algorithm Design

### Case Study: Binary Search

In "Generic Programming," Parent compares a traditional implementation of binary search (like the one in Jon Bentley's _Programming Pearls_) with the STL's `lower_bound`.

#### The Traditional Approach (Jon Bentley)

```cpp
int binary_search(int x[], int n, int v) {
    int l = 0;
    int u = n - 1;
    while (true) {
        if (l > u) return -1;
        int m = (l + u) / 2;
        if (x[m] < v) l = m + 1;
        else if (x[m] == v) return m;
        else u = m - 1;
    }
}
```

**Issues:**

- **Limited to integers:** Hard-coded types and indices.
- **Inclusive ranges:** Using `n - 1` and `-1` for failure makes the logic brittle.
- **Information loss:** If the value isn't found, it returns `-1`, losing the information of where the value _should_ have been.

#### The Generic Approach (STL `lower_bound`)

```cpp
template <class I, class T>
I lower_bound(I f, I l, const T& v) {
    while (f != l) {
        auto m = next(f, distance(f, l) / 2);
        if (*m < v) f = next(m);
        else l = m;
    }
    return f;
}
```

**Advantages:**

- **Half-Open Ranges:** Uses `[first, last)` which simplifies logic and boundary conditions.
- **No Information Loss:** Returns the first position where `v` could be inserted while maintaining order.
- **Minimal Requirements:** Works on any `ForwardIterator` (multi-pass), not just `RandomAccessIterator`.
- **Compositional:** This single primitive can be used to implement `binary_search`, `equal_range`, `insert_into_sorted_list`, etc.

### Stepanov's Approach

1. **Start with mathematics**: What is the abstract problem?
2. **Define concepts**: What properties must types have?
3. **Write the algorithm**: Express it generically
4. **Prove correctness**: Mathematical verification
5. **Analyze complexity**: Time and space requirements

## Refinements and Hierarchies

### Iterator Hierarchy

```
InputIterator      OutputIterator
      |                  |
ForwardIterator ←─────────┘
      |
BidirectionalIterator
      |
RandomAccessIterator
      |
ContiguousIterator (C++20)
```

### Algorithm Selection

Algorithms can be optimized based on iterator capabilities:

```cpp
// Generic distance (O(n) for InputIterator)
template<typename InputIt>
auto distance_impl(InputIt first, InputIt last, std::input_iterator_tag) {
    typename std::iterator_traits<InputIt>::difference_type n = 0;
    while (first != last) {
        ++first;
        ++n;
    }
    return n;
}

// Optimized for RandomAccessIterator (O(1))
template<typename RandomIt>
auto distance_impl(RandomIt first, RandomIt last, std::random_access_iterator_tag) {
    return last - first;
}

template<typename It>
auto distance(It first, It last) {
    return distance_impl(first, last,
        typename std::iterator_traits<It>::iterator_category{});
}
```

## The Power of Composition

### Algorithm Composition

Simple algorithms compose to solve complex problems:

```cpp
// rotate + partition = stable_partition
// rotate + merge = merge_sort
// rotate + lower_bound = insert into sorted position

// Example: move element at 'from' to position 'to'
template<typename It>
void slide_element(It first, It from, It to) {
    if (from < to) {
        std::rotate(from, from + 1, to + 1);
    } else if (to < from) {
        std::rotate(to, from, from + 1);
    }
}
```

### Building Higher-Level Abstractions

```cpp
// gather: collect elements matching predicate around a point
template<typename BidirIt, typename Pred>
auto gather(BidirIt first, BidirIt last, BidirIt pos, Pred pred) {
    return std::make_pair(
        std::stable_partition(first, pos, std::not_fn(pred)),
        std::stable_partition(pos, last, pred)
    );
}

// Usage: gather all selected items around cursor
auto [gfirst, glast] = gather(items.begin(), items.end(), cursor, is_selected);
```

## Modern Generic Programming (C++20)

### Concepts

```cpp
template<std::integral T>
T gcd(T a, T b) {
    while (b != 0) {
        auto t = b;
        b = a % b;
        a = t;
    }
    return a;
}

template<std::ranges::range R>
void print(const R& r) {
    for (const auto& x : r) {
        std::cout << x << ' ';
    }
}
```

### Ranges

```cpp
#include <ranges>

// Composable range operations
auto result = numbers
    | std::views::filter([](int n) { return n % 2 == 0; })
    | std::views::transform([](int n) { return n * n; })
    | std::views::take(10);

// Range algorithms
std::ranges::sort(container);
auto it = std::ranges::find(container, value);
```

### Constexpr Algorithms

```cpp
// Compile-time computation
constexpr auto sorted_array = [] {
    std::array<int, 5> arr = {3, 1, 4, 1, 5};
    std::ranges::sort(arr);
    return arr;
}();

static_assert(sorted_array == std::array{1, 1, 3, 4, 5});
```

## Guidelines

### 1. Think in Concepts

```cpp
// Don't think "vector of ints"
// Think "sortable range of comparable elements"

template<std::ranges::random_access_range R>
    requires std::sortable<std::ranges::iterator_t<R>>
void sort(R&& range);
```

### 2. Separate Algorithms from Containers

```cpp
// BAD: Algorithm tied to container
class MyVector {
    void sort() { /* sorting code */ }
};

// GOOD: Algorithm works with any range
template<typename It>
void sort(It first, It last);

MyVector v;
sort(v.begin(), v.end());
```

### 3. Require Only What You Need

```cpp
// BAD: Requires too much
template<typename Container>
void process(Container& c) {
    // Only uses forward traversal, but requires random access
    for (auto& x : c) { /* ... */ }
}

// GOOD: Minimal requirements
template<std::ranges::input_range R>
void process(R&& r) {
    for (auto& x : r) { /* ... */ }
}
```

### 4. Document Semantic Requirements

```cpp
/// Finds the first element equal to value
/// @tparam It Forward iterator type
/// @tparam T Value type comparable with *It
/// @pre [first, last) is a valid range
/// @pre T is equality-comparable with iterator's value type
/// @complexity O(last - first) comparisons
template<typename It, typename T>
It find(It first, It last, const T& value);
```

## References

### Primary Sources

- **[Generic Programming (code::dive 2018)](https://www.youtube.com/watch?v=FX78-1uBCNA)** — Sean Parent's talk
- **[Generic Programming (pacific++ 2018)](https://www.youtube.com/watch?v=iwJpxWHuZQY)** — Same talk, different venue
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2018-11-08-generic-programming/2018-11-08-generic-programming.pdf)**

### Foundational Works

- **[Elements of Programming](http://elementsofprogramming.com/)** — Stepanov and McJones
- **[From Mathematics to Generic Programming](http://www.fm2gp.com/)** — Stepanov and Rose
- **[Notes on Programming](http://stepanovpapers.com/notes.pdf)** — Stepanov's lecture notes

### C++20 Concepts

- **[cppreference: Concepts](https://en.cppreference.com/w/cpp/concepts)**
- **[cppreference: Ranges](https://en.cppreference.com/w/cpp/ranges)**

---

_"Generic programming is about writing algorithms that are as general as possible without losing efficiency."_ — Alexander Stepanov
