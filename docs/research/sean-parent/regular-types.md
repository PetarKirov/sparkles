# Regular Types and Complete Types

> "A type is regular if it behaves like int."

## Overview

The concept of "regular types" is foundational to generic programming and comes from Alexander Stepanov's work on the STL and his book "Elements of Programming" (co-authored with Paul McJones). Sean Parent championed these ideas in his talk "Goal: Implement Complete & Efficient Types" and throughout his Better Code series.

Sean Parent emphasizes that objects are **physical entities**—representations of an entity as a value in memory. A type is a pattern for storing and modifying these objects.

## What Makes a Type Regular?

A regular type models the behavior of built-in types like `int`. It must support a set of fundamental procedures in its **computational basis** that allow it to be stored in data structures and used with generic algorithms.

### Required Operations

| Operation            | Syntax     | Semantics                                                               |
| -------------------- | ---------- | ----------------------------------------------------------------------- |
| Default construction | `T a;`     | Creates a **partially-formed** object (safe to destroy or assign to)    |
| Copy construction    | `T a = b;` | Creates `a` such that `a == b`                                          |
| Copy assignment      | `a = b;`   | Makes `a == b` without modifying `b`                                    |
| Destruction          | `~T()`     | Releases resources; must be safe for partially-formed objects           |
| Equality             | `a == b`   | True if values correspond to the same entity (must be a total function) |
| Inequality           | `a != b`   | Equivalent to `!(a == b)`                                               |

### Partially-Formed State

A key concept in Parent's philosophy is the **partially-formed state**. An object is partially-formed if it has been constructed or moved from, but its internal value is uninitialized or violates invariants.

- **The only safe operations** on a partially-formed object are **destruction** and **assignment**.
- Default construction of a type with no natural default value (like a `File` or `Socket`) should result in a partially-formed state.

### Strongly Recommended Operations

| Operation         | Syntax                | Semantics                                         |
| ----------------- | --------------------- | ------------------------------------------------- |
| Move construction | `T a = std::move(b);` | Optimization of copy; leaves `b` partially-formed |
| Move assignment   | `a = std::move(b);`   | Optimization of copy; leaves `b` partially-formed |
| Swap              | `swap(a, b);`         | Exchange values; must be efficient                |
| Ordering          | `a < b`               | Total ordering (if applicable)                    |

## Regular vs. Complete Types

Sean Parent distinguishes between a type being **Regular** and being **Complete**:

1.  **Regular**: The type supports the standard basis (copy, assignment, equality) with standard semantics, allowing it to work with standard containers and algorithms.
2.  **Complete**: A type is complete if its set of basis operations allows for the construction and manipulation of **any valid representable value** of that type.

An **Incomplete Type** (in this context) is one where certain valid states are unreachable through the public interface, or where operations are missing that are necessary to use the type effectively as a value.

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

Sean Parent defines the **computational basis** of a type as the set of fundamental procedures that can be used to implement all other operations and reach all valid states.

### Minimal Basis

To achieve regularity, a type must implement at least:

1.  **Copy constructor**: `T(const T&)`
2.  **Destructor**: `~T()`
3.  **Equality**: `operator==(const T&, const T&)`

### Extended Basis

From this minimal basis, all other regular operations can be derived (though often less efficiently):

- **Assignment**: Can be implemented via `copy` + `swap` or `destroy` + `copy-construct`.
- **Inequality**: `!(a == b)`.
- **Move operations**: An optimization of copy.
- **Swap**: Can be implemented via move operations.

### Totality

For a type to be **Regular**, the basis operations must be **total functions**. They must be defined for all possible values of the type. If an operation (like equality) is only defined for some values (like `double` with `NaN`), the type is only **Partially Regular**.

## Broken and Incomplete Types

### Broken Types (Violating Regularity)

A type is **broken** if it fails to satisfy the axioms of a regular type (reflexivity, symmetry, transitivity, and substitutability).

#### Non-Total Equality (Partial Regularity)

```cpp
// BAD: Equality isn't total (like floating-point NaN)
class MaybeValue {
    bool hasValue_ = false;
    int value_ = 0;
public:
    friend bool operator==(const MaybeValue& a, const MaybeValue& b) {
        if (!a.hasValue_ || !b.hasValue_) return false;  // NaN-like behavior
        return a.value_ == b.value_;
    }
};

MaybeValue empty;
assert(empty == empty);  // FAILS! Not reflexive. This is a Partial Regular Type.
```

#### Inconsistent Copy

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
assert(a == b);  // FAILS! Copy doesn't produce equal value.
```

### Incomplete Types (Unreachable States)

A type is **incomplete** if its basis does not allow for the construction or manipulation of every valid representable value.

```cpp
// INCOMPLETE: No way to set or get the 'secret' value
class Incomplete {
    int value_;
    int secret_; // No basis operation can touch this!
public:
    Incomplete(int v) : value_(v), secret_(0) {}
    friend bool operator==(const Incomplete& a, const Incomplete& b) {
        return a.value_ == b.value_ && a.secret_ == b.secret_;
    }
};
```

## Efficiency and Optimizations

While regularity is about correctness, Sean Parent also focuses on efficiency.

### Move is an Optimization of Copy

Move semantics should be viewed as an optimization of copy. A type that is moveable but not copyable (like `std::unique_ptr`) is **Semiregular** but not fully **Regular** because it lacks equality and the ability to be copied (violating the property that multiple copies are equal).

### Self-Assignment

Sean Parent argues against the common practice of checking for self-assignment (`if (this == &other)`) in assignment operators unless it is a significant performance win for a frequent case.

- **De-optimization**: In the 99.9% of cases where it is _not_ a self-assignment, you are adding a branch.
- **Correctness**: A correctly implemented assignment (like copy-and-swap) handles self-assignment naturally.

### The Role of Swap

`swap` is a fundamental optimization that allows algorithms like `std::rotate` or `std::sort` to operate efficiently on complex types without performing expensive deep copies.

## Default Operations

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
