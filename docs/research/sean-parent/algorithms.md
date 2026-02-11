# Algorithms and Composition

> "That's a rotate!"

## Overview

Sean Parent is famous for demonstrating how standard algorithms, particularly `std::rotate`, can solve problems that appear to require custom loops. His talks on algorithms emphasize mastering the standard library, understanding algorithm composition, and building new algorithms from existing primitives.

Key presentations include "C++ Seasoning", "What's Your Function?", "Better Code: Algorithms - Preliminaries", and "Better Code: Algorithms - Composition".

## Why Algorithms Matter

### 1. Express Intent

Algorithms describe _what_ you're doing, not _how_:

```cpp
// Loop: HOW to find
for (auto it = v.begin(); it != v.end(); ++it) {
    if (*it == target) return it;
}
return v.end();

// Algorithm: WHAT you're doing
return std::find(v.begin(), v.end(), target);
```

### 2. Correctness

Standard algorithms are tested and proven:

```cpp
// Loop: potential bugs
for (size_t i = 0; i <= v.size(); ++i) {  // Bug: <= instead of <
    process(v[i]);
}

// Algorithm: correct by construction
std::for_each(v.begin(), v.end(), process);
```

### 3. Performance

Algorithms can use optimized implementations:

```cpp
// std::copy can use memmove for trivially copyable types
// std::sort uses introsort (quicksort + heapsort + insertion sort)
// std::find can use SIMD on some platforms
```

### 4. Composability

Algorithms combine naturally:

```cpp
// Find the first negative number after the first positive
auto pos = std::find_if(v.begin(), v.end(), [](int x) { return x > 0; });
auto neg = std::find_if(pos, v.end(), [](int x) { return x < 0; });
```

## Essential Algorithms

### Non-Modifying Sequence Operations

| Algorithm                     | Purpose               | Example                                   |
| ----------------------------- | --------------------- | ----------------------------------------- |
| `find`, `find_if`             | Locate element        | `find(v.begin(), v.end(), 42)`            |
| `count`, `count_if`           | Count occurrences     | `count_if(v.begin(), v.end(), pred)`      |
| `all_of`, `any_of`, `none_of` | Test predicate        | `all_of(v.begin(), v.end(), pred)`        |
| `equal`                       | Compare ranges        | `equal(a.begin(), a.end(), b.begin())`    |
| `mismatch`                    | Find first difference | `mismatch(a.begin(), a.end(), b.begin())` |

### Modifying Sequence Operations

| Algorithm               | Purpose             | Example                                       |
| ----------------------- | ------------------- | --------------------------------------------- |
| `copy`, `copy_if`       | Copy elements       | `copy(src.begin(), src.end(), dst.begin())`   |
| `transform`             | Apply function      | `transform(v.begin(), v.end(), v.begin(), f)` |
| `fill`                  | Set all to value    | `fill(v.begin(), v.end(), 0)`                 |
| `generate`              | Fill with generator | `generate(v.begin(), v.end(), rand)`          |
| `remove`, `remove_if`   | Prepare for erase   | `remove_if(v.begin(), v.end(), pred)`         |
| `replace`, `replace_if` | Substitute values   | `replace(v.begin(), v.end(), old, new)`       |
| `swap_ranges`           | Exchange ranges     | `swap_ranges(a.begin(), a.end(), b.begin())`  |
| `reverse`               | Reverse order       | `reverse(v.begin(), v.end())`                 |
| `rotate`                | Cycle elements      | `rotate(v.begin(), v.begin() + k, v.end())`   |

### Partitioning Operations

| Algorithm          | Purpose                 | Stability |
| ------------------ | ----------------------- | --------- |
| `partition`        | Divide by predicate     | Unstable  |
| `stable_partition` | Divide preserving order | Stable    |
| `partition_point`  | Find partition boundary | -         |
| `is_partitioned`   | Test if partitioned     | -         |

### Sorting Operations

| Algorithm      | Purpose                     | Complexity |
| -------------- | --------------------------- | ---------- |
| `sort`         | Sort range                  | O(n log n) |
| `stable_sort`  | Sort preserving equal order | O(n log n) |
| `partial_sort` | Sort first k elements       | O(n log k) |
| `nth_element`  | Put nth element in place    | O(n)       |
| `is_sorted`    | Check if sorted             | O(n)       |

### Binary Search (Sorted Ranges)

| Algorithm       | Purpose                 |
| --------------- | ----------------------- |
| `lower_bound`   | First element ≥ value   |
| `upper_bound`   | First element > value   |
| `equal_range`   | Range of equal elements |
| `binary_search` | Check if present        |

### Numeric Operations (`<numeric>`)

| Algorithm             | Purpose                       |
| --------------------- | ----------------------------- |
| `accumulate`          | Fold left                     |
| `reduce`              | Parallel fold                 |
| `inner_product`       | Dot product                   |
| `partial_sum`         | Running total                 |
| `adjacent_difference` | Consecutive differences       |
| `iota`                | Fill with incrementing values |

## The Power of Rotate

Sean Parent's favorite algorithm, `std::rotate`, is surprisingly versatile:

```cpp
// rotate(first, middle, last)
// Moves [middle, last) to the front
// Returns iterator to original first element in new position

std::vector<int> v = {1, 2, 3, 4, 5};
auto it = std::rotate(v.begin(), v.begin() + 2, v.end());
// v = {3, 4, 5, 1, 2}
// it points to 1
```

### Rotate Use Cases

**1. Move element to front:**

```cpp
auto it = std::find(v.begin(), v.end(), target);
if (it != v.end()) {
    std::rotate(v.begin(), it, it + 1);
}
```

**2. Move element to back:**

```cpp
auto it = std::find(v.begin(), v.end(), target);
if (it != v.end()) {
    std::rotate(it, it + 1, v.end());
}
```

**3. Insert at position (after element exists):**

```cpp
// Move element at 'from' to position 'to'
if (from < to) {
    std::rotate(from, from + 1, to + 1);
} else {
    std::rotate(to, from, from + 1);
}
```

## Slide: Moving a Range

Sean Parent introduced the `slide` algorithm for moving a subrange:

```cpp
template<typename I>  // I models RandomAccessIterator
auto slide(I first, I last, I pos) -> std::pair<I, I> {
    if (pos < first) return { pos, std::rotate(pos, first, last) };
    if (last < pos)  return { std::rotate(first, last, pos), pos };
    return { first, last };
}
```

Usage:

```cpp
std::vector<int> v = {1, 2, 3, 4, 5, 6, 7};
// Move [3, 4, 5] to position after 6
auto [new_first, new_last] = slide(v.begin() + 2, v.begin() + 5, v.begin() + 6);
// v = {1, 2, 6, 3, 4, 5, 7}
```

## Gather: Collecting Elements

The `gather` algorithm collects elements matching a predicate around a position:

```cpp
template<typename I, typename P>
auto gather(I first, I last, I pos, P pred) -> std::pair<I, I> {
    return {
        std::stable_partition(first, pos, std::not_fn(pred)),
        std::stable_partition(pos, last, pred)
    };
}
```

Usage:

```cpp
std::vector<int> v = {1, 2, 3, 4, 5, 6, 7, 8, 9};
auto is_even = [](int x) { return x % 2 == 0; };

// Gather even numbers around position 4
auto [gfirst, glast] = gather(v.begin(), v.end(), v.begin() + 4, is_even);
// v might be: {1, 3, 5, 2, 4, 6, 8, 7, 9}
//                     ^^^^^^^^^^^^ even numbers gathered
```

## Algorithm Composition Patterns

### Erase-Remove Idiom

```cpp
// Remove elements matching predicate
v.erase(
    std::remove_if(v.begin(), v.end(), pred),
    v.end()
);

// C++20 version
std::erase_if(v, pred);
```

### Transform-Accumulate

```cpp
// Sum of squares
auto sum_of_squares = std::transform_reduce(
    v.begin(), v.end(),
    0,                           // Initial value
    std::plus<>{},               // Reduce operation
    [](int x) { return x * x; }  // Transform operation
);
```

### Partition-Based Algorithms

```cpp
// Move all zeros to the end
auto boundary = std::stable_partition(
    v.begin(), v.end(),
    [](int x) { return x != 0; }
);
// Now [v.begin(), boundary) are non-zeros
// [boundary, v.end()) are zeros
```

### Finding Unique Elements

```cpp
// Sort and remove duplicates
std::sort(v.begin(), v.end());
v.erase(
    std::unique(v.begin(), v.end()),
    v.end()
);
```

## Building Custom Algorithms

### Traits for Algorithm Selection

```cpp
template<typename I>
struct is_random_access_iterator : std::bool_constant<
    std::is_same_v<
        typename std::iterator_traits<I>::iterator_category,
        std::random_access_iterator_tag
    >
> {};

template<typename I>
void advance_impl(I& it, int n, std::random_access_iterator_tag) {
    it += n;  // O(1)
}

template<typename I>
void advance_impl(I& it, int n, std::input_iterator_tag) {
    while (n-- > 0) ++it;  // O(n)
}
```

### Algorithm Customization Points

```cpp
// Using swap customization point
template<typename I>
void my_reverse(I first, I last) {
    while (first != last && first != --last) {
        using std::swap;
        swap(*first++, *last);  // ADL finds custom swap
    }
}
```

## Guidelines for Using Algorithms

### 1. Know What's Available

Before writing a loop, check if an algorithm exists:

```cpp
// Don't write this loop:
bool found = false;
for (const auto& x : v) {
    if (pred(x)) { found = true; break; }
}

// Use this instead:
bool found = std::any_of(v.begin(), v.end(), pred);
```

### 2. Prefer Named Operations

```cpp
// Instead of:
auto it = std::find_if(v.begin(), v.end(), [](auto& x) { return x.active; });

// Consider:
auto is_active = [](const auto& x) { return x.active; };
auto it = std::find_if(v.begin(), v.end(), is_active);

// Or even better, define at class scope:
auto it = std::find_if(v.begin(), v.end(), &Item::is_active);
```

### 3. Use Ranges (C++20)

```cpp
// Traditional
std::sort(v.begin(), v.end());
auto it = std::find(v.begin(), v.end(), target);

// Ranges
std::ranges::sort(v);
auto it = std::ranges::find(v, target);

// With views (lazy)
auto evens = v | std::views::filter([](int x) { return x % 2 == 0; })
               | std::views::transform([](int x) { return x * 2; });
```

### 4. Compose, Don't Loop

```cpp
// Instead of nested loops:
std::vector<std::pair<int, int>> pairs;
for (auto a : v1) {
    for (auto b : v2) {
        if (pred(a, b)) pairs.emplace_back(a, b);
    }
}

// Compose algorithms (with ranges):
auto pairs = std::views::cartesian_product(v1, v2)  // C++23
           | std::views::filter([](auto p) { return pred(p.first, p.second); })
           | std::ranges::to<std::vector>();
```

### 5. Understand Complexity

Choose algorithms based on complexity requirements:

```cpp
// O(n) - single pass needed
std::find_if(v.begin(), v.end(), pred);

// O(n log n) - sorting acceptable
std::sort(v.begin(), v.end());

// O(log n) - requires sorted input
std::lower_bound(v.begin(), v.end(), target);

// O(1) amortized - for frequent access by key
std::unordered_map<K, V> map;
```

## Anti-Patterns

### Reimplementing Standard Algorithms

```cpp
// BAD: Manual binary search
int low = 0, high = v.size() - 1;
while (low <= high) {
    int mid = low + (high - low) / 2;
    if (v[mid] == target) return mid;
    if (v[mid] < target) low = mid + 1;
    else high = mid - 1;
}
return -1;

// GOOD: Use standard algorithm
auto it = std::lower_bound(v.begin(), v.end(), target);
if (it != v.end() && *it == target) return it - v.begin();
return -1;
```

### Using Wrong Algorithm

```cpp
// BAD: Using sort when you only need nth element
std::sort(v.begin(), v.end());
auto median = v[v.size() / 2];

// GOOD: Use nth_element (O(n) vs O(n log n))
std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end());
auto median = v[v.size() / 2];
```

## References

### Primary Sources

- **[C++ Seasoning](https://sean-parent.stlab.cc/presentations/2013-09-11-cpp-seasoning/cpp-seasoning.pdf)** — Original algorithms talk
- **[What's Your Function? (YouTube)](https://www.youtube.com/watch?v=DnfRMYCw_Y4)** — Function and algorithm design
- **[Better Code: Algorithms - Preliminaries (YouTube)](https://www.youtube.com/watch?v=wtOkvB_iFw4)** — Foundations
- **[Better Code: Algorithms - Composition (YouTube)](https://www.youtube.com/watch?v=HJb6Czi0Ky0)** — Composing algorithms

### Further Reading

- **[cppreference.com Algorithms](https://en.cppreference.com/w/cpp/algorithm)** — Complete reference
- **[Elements of Programming](http://elementsofprogramming.com/)** — Theoretical foundations

---

_"If you want to improve the code quality in your organization, replace all of your coding guidelines with one goal: No Raw Loops."_ — Sean Parent
