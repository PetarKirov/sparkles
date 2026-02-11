# Value Semantics and Concept-Based Polymorphism

> "Inheritance is the base class of evil."

## Overview

Sean Parent's work on value semantics and concept-based polymorphism presents an alternative to classical object-oriented programming that avoids many of its pitfalls. Instead of using inheritance hierarchies with virtual functions, this approach uses type erasure and concepts to achieve runtime polymorphism while preserving value semantics.

This is explored in his seminal talks "Value Semantics and Concept-based Polymorphism" and "Inheritance Is The Base Class of Evil" from GoingNative 2013.

## The Problems with Classical Inheritance

### 1. Fragile Base Class Problem

Changes to a base class can break derived classes in unexpected ways:

```cpp
class Base {
public:
    virtual void process() {
        step1();
        step2();
    }
    virtual void step1() { /* ... */ }
    virtual void step2() { /* ... */ }
};

class Derived : public Base {
public:
    void step1() override {
        Base::step1();
        additionalWork();
    }
};

// Later, Base::process() is changed to call step1() twice
// Derived is silently broken
```

### 2. Tight Coupling

Inheritance creates the strongest possible coupling between classes:

```cpp
class Animal {
public:
    virtual void makeSound() = 0;
    virtual void move() = 0;
    virtual ~Animal() = default;
};

// Every animal must inherit from Animal
// Can't use lambdas, existing types, or third-party types
```

### 3. Loss of Value Semantics

Inheritance typically requires pointers and heap allocation:

```cpp
// Must use pointers for polymorphism
std::vector<std::unique_ptr<Animal>> animals;

// Can't copy the vector naturally
// Deep copy requires clone() virtual method
// Slicing if you try to store by value
```

### 4. Interface Intrusion

Types must opt-in to the inheritance hierarchy:

```cpp
// Third-party class
class ThirdPartyDrawable {
public:
    void render();  // Not virtual, not our base class
};

// Can't add to std::vector<std::unique_ptr<Drawable>>
// without writing an adapter
```

## The Solution: Type Erasure

Type erasure allows polymorphism without inheritance by hiding the concrete type behind a uniform interface.

### The Basic Pattern

```cpp
class Drawable {
    struct Concept {
        virtual ~Concept() = default;
        virtual void draw_(std::ostream&) const = 0;
        virtual std::unique_ptr<Concept> clone_() const = 0;
    };

    template<typename T>
    struct Model : Concept {
        T data_;

        Model(T x) : data_(std::move(x)) {}

        void draw_(std::ostream& out) const override {
            draw(data_, out);  // Free function, not member!
        }

        std::unique_ptr<Concept> clone_() const override {
            return std::make_unique<Model>(*this);
        }
    };

    std::unique_ptr<Concept> self_;

public:
    template<typename T>
    Drawable(T x) : self_(std::make_unique<Model<T>>(std::move(x))) {}

    // Value semantics - copyable!
    Drawable(const Drawable& other) : self_(other.self_->clone_()) {}

    Drawable& operator=(Drawable other) {
        self_ = std::move(other.self_);
        return *this;
    }

    Drawable(Drawable&&) = default;
    Drawable& operator=(Drawable&&) = default;

    friend void draw(const Drawable& d, std::ostream& out) {
        d.self_->draw_(out);
    }
};
```

### Using the Type-Erased Wrapper

```cpp
// Any type with a draw() free function works
struct Circle {
    double radius;
};

void draw(const Circle& c, std::ostream& out) {
    out << "Circle(" << c.radius << ")";
}

struct Rectangle {
    double width, height;
};

void draw(const Rectangle& r, std::ostream& out) {
    out << "Rectangle(" << r.width << "x" << r.height << ")";
}

// Can store heterogeneous objects with value semantics
std::vector<Drawable> shapes;
shapes.push_back(Circle{5.0});
shapes.push_back(Rectangle{3.0, 4.0});

// Can copy the whole vector!
auto shapes2 = shapes;

// Draw all
for (const auto& shape : shapes) {
    draw(shape, std::cout);
}
```

## The Document Example

Sean Parent's classic example: a document containing drawable objects that supports undo.

### The Goal

```cpp
using Document = std::vector<Object>;

void draw(const Document& doc, std::ostream& out) {
    for (const auto& obj : doc) {
        draw(obj, out);
    }
}

int main() {
    Document doc;
    doc.push_back(Circle{10.0});
    doc.push_back(Rectangle{5.0, 3.0});

    // Make a copy for undo
    Document backup = doc;

    // Modify document
    doc.push_back(Circle{7.0});

    // Undo by restoring backup
    doc = backup;

    draw(doc, std::cout);
}
```

### The Implementation

```cpp
class Object {
    struct Concept {
        virtual ~Concept() = default;
        virtual std::unique_ptr<Concept> clone() const = 0;
        virtual void draw(std::ostream&) const = 0;
    };

    template<typename T>
    struct Model final : Concept {
        T data_;

        template<typename U>
        Model(U&& x) : data_(std::forward<U>(x)) {}

        std::unique_ptr<Concept> clone() const override {
            return std::make_unique<Model>(*this);
        }

        void draw(std::ostream& out) const override {
            ::draw(data_, out);  // ADL finds the right draw()
        }
    };

    std::unique_ptr<Concept> self_;

public:
    template<typename T,
             typename = std::enable_if_t<!std::is_same_v<std::decay_t<T>, Object>>>
    Object(T&& x) : self_(std::make_unique<Model<std::decay_t<T>>>(std::forward<T>(x))) {}

    Object(const Object& x) : self_(x.self_->clone()) {}
    Object(Object&&) noexcept = default;

    Object& operator=(Object x) noexcept {
        self_ = std::move(x.self_);
        return *this;
    }

    friend void draw(const Object& x, std::ostream& out) {
        x.self_->draw(out);
    }
};
```

## Benefits of Type Erasure

### 1. Non-Intrusive

Types don't need to inherit from anything:

```cpp
// Works with any type that has a draw() function
struct Triangle { /* ... */ };
void draw(const Triangle&, std::ostream&);

// Works with lambdas!
Object obj = [](std::ostream& out) { out << "Lambda!"; };

// Works with third-party types (with adapter)
struct ThirdPartyAdapter {
    ThirdPartyWidget widget;
};
void draw(const ThirdPartyAdapter& a, std::ostream& out) {
    a.widget.render(out);
}
```

### 2. Value Semantics Preserved

```cpp
std::vector<Object> doc1;
doc1.push_back(Circle{5.0});

// Natural copy
std::vector<Object> doc2 = doc1;

// Independent
doc1.push_back(Rectangle{3.0, 4.0});
// doc2 still has only the circle
```

### 3. Easy Undo/Redo

```cpp
class DocumentWithHistory {
    using Document = std::vector<Object>;

    Document current_;
    std::vector<Document> history_;
    size_t historyIndex_ = 0;

public:
    void modify(auto&& action) {
        history_.resize(historyIndex_);
        history_.push_back(current_);
        ++historyIndex_;
        action(current_);
    }

    void undo() {
        if (historyIndex_ > 0) {
            --historyIndex_;
            current_ = history_[historyIndex_];
        }
    }

    void redo() {
        if (historyIndex_ < history_.size()) {
            current_ = history_[historyIndex_];
            ++historyIndex_;
        }
    }
};
```

### 4. Composable

```cpp
// Group is itself drawable
struct Group {
    std::vector<Object> objects;
};

void draw(const Group& g, std::ostream& out) {
    for (const auto& obj : g.objects) {
        draw(obj, out);
    }
}

// Groups can contain groups!
Group nested;
nested.objects.push_back(Circle{1.0});
nested.objects.push_back(Group{{Rectangle{2.0, 3.0}, Circle{4.0}}});
```

## Small Buffer Optimization

For better performance, avoid heap allocation for small objects:

```cpp
class Object {
    struct Concept { /* ... */ };

    template<typename T>
    struct Model : Concept { /* ... */ };

    // Small buffer for small objects
    static constexpr size_t BufferSize = 64;
    alignas(std::max_align_t) std::byte buffer_[BufferSize];

    Concept* self_ = nullptr;

    template<typename T>
    static constexpr bool fits_in_buffer =
        sizeof(Model<T>) <= BufferSize &&
        alignof(Model<T>) <= alignof(std::max_align_t);

public:
    template<typename T>
    Object(T&& x) {
        using ModelT = Model<std::decay_t<T>>;
        if constexpr (fits_in_buffer<std::decay_t<T>>) {
            self_ = new (buffer_) ModelT(std::forward<T>(x));
        } else {
            self_ = new ModelT(std::forward<T>(x));
        }
    }

    ~Object() {
        if (is_in_buffer()) {
            self_->~Concept();
        } else {
            delete self_;
        }
    }

    // ... rest of implementation
};
```

## Comparison: Inheritance vs Type Erasure

| Aspect            | Inheritance          | Type Erasure                  |
| ----------------- | -------------------- | ----------------------------- |
| Coupling          | Tight (must inherit) | Loose (just provide function) |
| Value semantics   | Lost (need pointers) | Preserved                     |
| Third-party types | Need adapter class   | Just provide free function    |
| Lambdas           | Can't use            | Natural                       |
| Copy              | Need clone() method  | Automatic                     |
| Undo/Redo         | Complex              | Simple (copy state)           |
| Performance       | Virtual call         | Virtual call + possible heap  |
| Compile time      | Fast                 | Slower (templates)            |

## When to Use Each

### Use Inheritance When:

- Interface is large and complex
- Performance is critical (no heap allocation)
- Types are always used polymorphically
- Existing codebase uses it

### Use Type Erasure When:

- Value semantics are important
- Need to support third-party/existing types
- Want to support lambdas
- Need easy copy/undo semantics
- Interface is small (1-3 functions)

## Standard Library Examples

The standard library uses type erasure in several places:

- `std::function<R(Args...)>` — Callable wrapper
- `std::any` — Hold any type
- `std::move_only_function` (C++23) — Non-copyable callable

```cpp
// std::function is type erasure
std::function<void()> callback;
callback = []{ std::cout << "Lambda!"; };
callback = std::bind(&SomeClass::method, &obj);
callback = funcPtr;
```

## Guidelines

1. **Prefer value semantics** — Design types to be copied and assigned naturally
2. **Use free functions for interfaces** — More flexible than member functions
3. **Consider type erasure for small interfaces** — 1-3 functions work well
4. **Use small buffer optimization** — Avoid heap for common cases
5. **Make the concept minimal** — Only erase what you need
6. **Leverage ADL** — Let argument-dependent lookup find the right functions

## References

### Primary Sources

- **[Value Semantics and Concept-based Polymorphism (YouTube)](https://www.youtube.com/watch?v=_BpMYeUFXv8)** — C++Now 2012
- **[Inheritance Is The Base Class of Evil (Channel 9)](https://channel9.msdn.com/Events/GoingNative/2013/Inheritance-Is-The-Base-Class-of-Evil)** — GoingNative 2013
- **[Better Code: Runtime Polymorphism (YouTube)](https://www.youtube.com/watch?v=QGcVXgEVMJg)** — NDC London 2017
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2013-09-24-value-semantics/value-semantics.pdf)**
- **[Source Code](https://sean-parent.stlab.cc/presentations/2013-03-06-value_semantics/value-semantics.cpp)**

### Related Resources

- **[Concept-Model Idiom](https://gracicot.github.io/conceptmodel/2017/09/13/concept-model-part1.html)** — Detailed explanation
- **[Step-by-step Implementation](https://github.com/tee3/value-semantics)** — Educational implementation

---

_"Polymorphism is not about classes and virtual functions. It's about types and operations on types."_ — Sean Parent
