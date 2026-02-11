# Regular Types and Complete Types

> "A type is regular if it behaves like int."

## Overview

The concept of "regular types" is foundational to generic programming and comes from Alexander Stepanov's work on the STL and his book "Elements of Programming" (co-authored with Paul McJones). Sean Parent championed these ideas in his talk "Goal: Implement Complete & Efficient Types" and throughout his Better Code series.

A regular type is one that supports a fundamental set of operations that allow it to work correctly with standard algorithms and containers. Implementing complete types—types that support all the expected operations with correct semantics—is essential for building robust, composable software.

## What Makes a Type Regular?

A regular type models the behavior of built-in types like `int`. It must support:

### Required Operations

| Operation            | Syntax     | Semantics                         |
| -------------------- | ---------- | --------------------------------- |
| Default construction | `T a;`     | Creates a partially-formed object |
| Copy construction    | `T a = b;` | Creates `a` such that `a == b`    |
| Copy assignment      | `a = b;`   | Makes `a == b`                    |
| Destruction          | `~T()`     | Releases resources                |
| Equality             | `a == b`   | True if values are the same       |
| Inequality           | `a != b`   | Equivalent to `!(a == b)`         |

### Strongly Recommended Operations

| Operation         | Syntax                | Semantics                      |
| ----------------- | --------------------- | ------------------------------ |
| Move construction | `T a = std::move(b);` | Efficiently transfers from `b` |
| Move assignment   | `a = std::move(b);`   | Efficiently transfers from `b` |
| Swap              | `swap(a, b);`         | Exchange values                |
| Ordering          | `a < b`               | Total ordering (if applicable) |

## Properties of Equality

Equality must satisfy these mathematical properties:

### Reflexivity

```cpp
a == a  // Always true
```

### Symmetry

```cpp
if (a == b) then (b == a)
```

### Transitivity

```cpp
if (a == b) and (b == c) then (a == c)
```

### Substitutability

Equal objects are interchangeable in any context:

```cpp
if (a == b) then f(a) == f(b)  // For any pure function f
```

## Properties of Copy

Copy operations must satisfy:

### Independence

After `T a = b;`, modifying `a` does not affect `b`:

```cpp
T a = b;
modify(a);
assert(b == original_b);  // b unchanged
```

### Equality Preservation

```cpp
T a = b;
assert(a == b);  // Copy produces equal value
```

### Multiple Copies Are Equal

```cpp
T a = x;
T b = x;
T c = x;
assert(a == b && b == c);
```

## Implementing Regular Types

### Basic Regular Type

```cpp
class Point {
    int x_ = 0;
    int y_ = 0;

public:
    // Default constructor
    Point() = default;

    // Value constructor
    Point(int x, int y) : x_(x), y_(y) {}

    // Copy operations (defaulted)
    Point(const Point&) = default;
    Point& operator=(const Point&) = default;

    // Move operations (defaulted)
    Point(Point&&) = default;
    Point& operator=(Point&&) = default;

    // Destructor (defaulted)
    ~Point() = default;

    // Equality
    friend bool operator==(const Point& a, const Point& b) {
        return a.x_ == b.x_ && a.y_ == b.y_;
    }

    friend bool operator!=(const Point& a, const Point& b) {
        return !(a == b);
    }

    // Ordering (if meaningful)
    friend bool operator<(const Point& a, const Point& b) {
        return std::tie(a.x_, a.y_) < std::tie(b.x_, b.y_);
    }

    // Swap
    friend void swap(Point& a, Point& b) noexcept {
        using std::swap;
        swap(a.x_, b.x_);
        swap(a.y_, b.y_);
    }
};
```

### Regular Type with Resources

When managing resources, use RAII and the Rule of Five:

```cpp
class Buffer {
    std::unique_ptr<char[]> data_;
    size_t size_ = 0;

public:
    // Default constructor
    Buffer() = default;

    // Value constructor
    explicit Buffer(size_t size)
        : data_(std::make_unique<char[]>(size))
        , size_(size)
    {}

    // Copy constructor - deep copy
    Buffer(const Buffer& other)
        : data_(other.size_ ? std::make_unique<char[]>(other.size_) : nullptr)
        , size_(other.size_)
    {
        if (size_) {
            std::copy_n(other.data_.get(), size_, data_.get());
        }
    }

    // Copy assignment - copy and swap idiom
    Buffer& operator=(const Buffer& other) {
        Buffer temp(other);
        swap(*this, temp);
        return *this;
    }

    // Move constructor
    Buffer(Buffer&& other) noexcept
        : data_(std::move(other.data_))
        , size_(std::exchange(other.size_, 0))
    {}

    // Move assignment
    Buffer& operator=(Buffer&& other) noexcept {
        Buffer temp(std::move(other));
        swap(*this, temp);
        return *this;
    }

    // Destructor - unique_ptr handles cleanup
    ~Buffer() = default;

    // Equality - compare contents
    friend bool operator==(const Buffer& a, const Buffer& b) {
        if (a.size_ != b.size_) return false;
        return std::equal(a.data_.get(), a.data_.get() + a.size_,
                          b.data_.get());
    }

    friend bool operator!=(const Buffer& a, const Buffer& b) {
        return !(a == b);
    }

    // Swap
    friend void swap(Buffer& a, Buffer& b) noexcept {
        using std::swap;
        swap(a.data_, b.data_);
        swap(a.size_, b.size_);
    }

    // Accessors
    size_t size() const { return size_; }
    char* data() { return data_.get(); }
    const char* data() const { return data_.get(); }
};
```

## The Copy-and-Swap Idiom

The copy-and-swap idiom provides a simple, exception-safe way to implement assignment:

```cpp
class String {
    char* data_ = nullptr;
    size_t size_ = 0;

public:
    // ... constructors ...

    // Copy assignment using copy-and-swap
    String& operator=(String other) {  // Pass by value (makes copy)
        swap(*this, other);             // Swap with copy
        return *this;                   // Old data destroyed with other
    }

    friend void swap(String& a, String& b) noexcept {
        using std::swap;
        swap(a.data_, b.data_);
        swap(a.size_, b.size_);
    }
};
```

Benefits:

- **Exception safety**: If copy throws, original is unchanged
- **Self-assignment safety**: Works correctly for `a = a`
- **Simple**: One implementation handles both copy and move

## Basis Operations

Sean Parent defines the "basis" of a type as the minimal set of operations needed to define all other operations:

### Minimal Basis

1. **Copy constructor**: `T(const T&)`
2. **Destructor**: `~T()`
3. **Equality**: `operator==(const T&, const T&)`

### Extended Basis

From the minimal basis, we can derive:

- **Assignment** from copy + destroy
- **Inequality** from equality
- **Move** operations (optimization of copy)
- **Swap** from move operations

### Default Operations

In C++11 and later, prefer defaulted operations when possible:

```cpp
class Widget {
    std::string name_;
    std::vector<int> data_;

public:
    Widget() = default;
    Widget(const Widget&) = default;
    Widget(Widget&&) = default;
    Widget& operator=(const Widget&) = default;
    Widget& operator=(Widget&&) = default;
    ~Widget() = default;

    friend bool operator==(const Widget&, const Widget&) = default;  // C++20
};
```

## Incomplete Types: Common Problems

### Missing Equality

```cpp
// BAD: No equality comparison
class Bad {
    int value_;
public:
    Bad(int v) : value_(v) {}
    // No operator==
};

std::vector<Bad> v;
auto it = std::find(v.begin(), v.end(), Bad(42));  // Won't compile!
```

### Inconsistent Copy

```cpp
// BAD: Copy doesn't produce equal objects
class Broken {
    int id_;
    static int nextId_;
public:
    Broken() : id_(nextId_++) {}
    Broken(const Broken&) : id_(nextId_++) {}  // Different ID!

    friend bool operator==(const Broken& a, const Broken& b) {
        return a.id_ == b.id_;
    }
};

Broken a;
Broken b = a;
assert(a == b);  // FAILS! Copy doesn't produce equal value
```

### Non-Total Equality

```cpp
// BAD: Equality isn't total (like floating-point NaN)
class MaybeValue {
    bool hasValue_;
    int value_;
public:
    friend bool operator==(const MaybeValue& a, const MaybeValue& b) {
        if (!a.hasValue_ || !b.hasValue_) return false;  // NaN-like behavior
        return a.value_ == b.value_;
    }
};

MaybeValue empty;
assert(empty == empty);  // FAILS! Not reflexive
```

## Guidelines

### Guideline 1: Default When Possible

Let the compiler generate operations when it can:

```cpp
class Good {
    std::string name_;
    std::vector<int> data_;
    // All operations defaulted automatically
};
```

### Guideline 2: If You Define One, Define All

The Rule of Five: if you define any of destructor, copy constructor, copy assignment, move constructor, or move assignment, consider defining all of them:

```cpp
class Resource {
    int* data_;
public:
    ~Resource() { delete data_; }
    Resource(const Resource&);             // Must define
    Resource& operator=(const Resource&);  // Must define
    Resource(Resource&&) noexcept;         // Should define
    Resource& operator=(Resource&&) noexcept;  // Should define
};
```

### Guideline 3: Make Move Operations noexcept

Move operations should never throw:

```cpp
class Container {
public:
    Container(Container&& other) noexcept;
    Container& operator=(Container&& other) noexcept;
};
```

This enables optimizations in standard containers.

### Guideline 4: Provide Strong Exception Guarantee

Assignment should either succeed or leave the original unchanged:

```cpp
// Strong guarantee via copy-and-swap
Container& operator=(Container other) {
    swap(*this, other);  // noexcept
    return *this;
}
```

### Guideline 5: Test Your Types

Verify regular type properties:

```cpp
template<typename T>
void testRegular(T a, T b, T c) {
    // Reflexivity
    assert(a == a);

    // Symmetry
    assert((a == b) == (b == a));

    // Transitivity (if a == b && b == c)
    if (a == b && b == c) assert(a == c);

    // Copy produces equality
    T copy = a;
    assert(copy == a);

    // Copy independence
    T copy2 = a;
    // modify copy2
    assert(a == copy);  // Original unchanged
}
```

## References

### Primary Sources

- **[Goal: Implement Complete & Efficient Types (YouTube)](https://www.youtube.com/watch?v=mYrbivnruYw)** — C++Now 2014 talk
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2014-04-14-goal-complete-types/goal-complete-types.pdf)** — Presentation slides
- **[Elements of Programming](http://elementsofprogramming.com/)** — Book by Stepanov and McJones

### Related Concepts

- **C++20 `std::regular` Concept** — Standard library formalization
- **Rule of Zero/Three/Five** — Guidelines for special member functions

---

_"If you define a type that doesn't satisfy the requirements of regular, you're defining a type that doesn't work correctly with standard algorithms and containers."_ — Sean Parent
