# Generic Programming

> "Generic programming is not just another paradigm. It's the culmination of decades of work on how to write reusable, efficient code."

## Overview

Sean Parent's "Generic Programming" talk (code::dive 2018, pacific++ 2018) traces the history and principles of generic programming from its origins with Alexander Stepanov through its impact on C++ and modern software development. The talk emphasizes that generic programming is not merely "templates" but a fundamental approach to software construction based on mathematical abstraction.

## What Is Generic Programming?

Generic programming is:

1. **Writing algorithms that work on any type** satisfying certain requirements
2. **Separating algorithms from data structures** through abstract interfaces
3. **Designing with mathematical precision** using concepts and axioms
4. **Achieving efficiency through abstraction** rather than sacrificing it

```cpp
// Not generic: works only with int arrays
void sort_int_array(int* arr, int size);

// Generic: works with any random-access range
template<typename RandomIt>
void sort(RandomIt first, RandomIt last);

// More generic: works with any ordering
template<typename RandomIt, typename Compare>
void sort(RandomIt first, RandomIt last, Compare comp);
```

## Historical Context

### Origins: Stepanov and Musser

Alexander Stepanov and David Musser coined "generic programming" in 1988. Stepanov's key insight:

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

### Stepanov's Approach

1. **Start with mathematics**: What is the abstract problem?
2. **Define concepts**: What properties must types have?
3. **Write the algorithm**: Express it generically
4. **Prove correctness**: Mathematical verification
5. **Analyze complexity**: Time and space requirements

### Example: Binary Search

```cpp
// Mathematical definition:
// Find the first position where value could be inserted
// to maintain sorted order

// Concept requirements:
// - ForwardIterator: multi-pass traversal
// - Sorted range: values in non-decreasing order
// - Value comparable with iterator's value type

template<typename ForwardIt, typename T>
ForwardIt lower_bound(ForwardIt first, ForwardIt last, const T& value) {
    auto count = std::distance(first, last);

    while (count > 0) {
        auto step = count / 2;
        auto mid = first;
        std::advance(mid, step);

        if (*mid < value) {
            first = ++mid;
            count -= step + 1;
        } else {
            count = step;
        }
    }

    return first;
}

// Complexity: O(log n) comparisons, O(log n) or O(n) increments
// (depending on iterator category)
```

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
