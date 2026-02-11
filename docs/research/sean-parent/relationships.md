# Better Code: Relationships

> "Computer scientists are bad at relationships."

## Overview

Sean Parent's "Better Code: Relationships" talk addresses one of the most common sources of bugs in software: mismanaged relationships between objects. Nearly every program crash is rooted in a mismanaged relationship, yet developers spend most of their time discussing types and functions rather than the connections between them.

This document explores how to model relationships explicitly and safely.

## The Problem with Implicit Relationships

### Common Relationship Bugs

1. **Dangling references**: Object A references object B, but B is destroyed
2. **Cycles**: Objects reference each other, preventing cleanup
3. **Inconsistent state**: A owns B, but B's parent pointer points elsewhere
4. **Order dependencies**: A must be destroyed before B, but nothing enforces this
5. **Hidden coupling**: Changes to A silently break B

### Example: The Observer Pattern Gone Wrong

```cpp
// Classic observer - what could go wrong?
class Subject {
    std::vector<Observer*> observers_;
public:
    void attach(Observer* o) { observers_.push_back(o); }
    void detach(Observer* o) {
        observers_.erase(std::remove(observers_.begin(), observers_.end(), o),
                        observers_.end());
    }
    void notify() {
        for (auto* o : observers_) {
            o->update();  // What if o was destroyed?
        }
    }
};

class Observer {
    Subject* subject_;
public:
    Observer(Subject* s) : subject_(s) { subject_->attach(this); }
    ~Observer() { subject_->detach(this); }  // What if subject_ was destroyed first?
    virtual void update() = 0;
};
```

Problems:

- Observer can outlive Subject (dangling `subject_` pointer)
- Subject can outlive Observer (dangling pointer in `observers_`)
- Notification during destruction causes undefined behavior
- No clear ownership

## Relationship Types

### 1. Ownership (Has-A)

One object owns another—owner controls lifetime:

```cpp
// Strong ownership: unique_ptr
class Document {
    std::unique_ptr<Content> content_;  // Document owns Content
};

// Value ownership: member object
class Document {
    Content content_;  // Document owns Content (best when possible)
};
```

### 2. Shared Ownership

Multiple objects share ownership—last one cleans up:

```cpp
// Shared ownership: shared_ptr
class Node {
    std::vector<std::shared_ptr<Node>> children_;
};

// Be careful: cycles cause leaks
class Node {
    std::shared_ptr<Node> parent_;  // BAD: cycle!
    std::vector<std::shared_ptr<Node>> children_;
};
```

### 3. Association (References-A)

Object references another without owning it:

```cpp
// Non-owning reference: raw pointer or reference
class Employee {
    Department* department_;  // Employee doesn't own Department
};

// With std::optional for nullable
class Employee {
    Department* department_ = nullptr;  // Nullable association
};
```

### 4. Weak Reference

Reference that doesn't prevent destruction:

```cpp
// Weak reference: weak_ptr
class Observer {
    std::weak_ptr<Subject> subject_;

    void update() {
        if (auto s = subject_.lock()) {
            // Subject still alive
        }
    }
};
```

## Relationship Management Patterns

### Pattern 1: Registry

Centralized management of object relationships:

```cpp
class Registry {
    std::unordered_map<EntityId, Entity> entities_;
    std::unordered_multimap<EntityId, EntityId> parent_to_children_;
    std::unordered_map<EntityId, EntityId> child_to_parent_;

public:
    EntityId create() {
        auto id = nextId();
        entities_.emplace(id, Entity{});
        return id;
    }

    void destroy(EntityId id) {
        // Remove from parent
        if (auto it = child_to_parent_.find(id); it != child_to_parent_.end()) {
            removeChild(it->second, id);
        }

        // Destroy children first
        auto [begin, end] = parent_to_children_.equal_range(id);
        std::vector<EntityId> children;
        for (auto it = begin; it != end; ++it) {
            children.push_back(it->second);
        }
        for (auto child : children) {
            destroy(child);
        }

        entities_.erase(id);
    }

    void setParent(EntityId child, EntityId parent) {
        // Remove from old parent
        if (auto it = child_to_parent_.find(child); it != child_to_parent_.end()) {
            removeChild(it->second, child);
        }

        // Add to new parent
        parent_to_children_.emplace(parent, child);
        child_to_parent_[child] = parent;
    }

private:
    void removeChild(EntityId parent, EntityId child) {
        auto [begin, end] = parent_to_children_.equal_range(parent);
        for (auto it = begin; it != end; ++it) {
            if (it->second == child) {
                parent_to_children_.erase(it);
                break;
            }
        }
        child_to_parent_.erase(child);
    }
};
```

### Pattern 2: Handle/Body (Pimpl)

Separate interface from implementation:

```cpp
// Handle (stable, copyable)
class Widget {
    struct Impl;
    std::shared_ptr<Impl> impl_;

public:
    Widget();
    void doSomething();
};

// Body (can change)
struct Widget::Impl {
    // Implementation details
};
```

### Pattern 3: Slot Map

Stable handles with generation counters:

```cpp
template<typename T>
class SlotMap {
    struct Slot {
        T data;
        uint32_t generation;
        bool occupied;
    };

    std::vector<Slot> slots_;
    std::vector<uint32_t> free_list_;

public:
    struct Handle {
        uint32_t index;
        uint32_t generation;
    };

    Handle insert(T value) {
        uint32_t index;
        if (!free_list_.empty()) {
            index = free_list_.back();
            free_list_.pop_back();
        } else {
            index = slots_.size();
            slots_.push_back({});
        }

        slots_[index].data = std::move(value);
        slots_[index].occupied = true;
        return {index, slots_[index].generation};
    }

    void erase(Handle h) {
        if (valid(h)) {
            slots_[h.index].occupied = false;
            slots_[h.index].generation++;
            free_list_.push_back(h.index);
        }
    }

    T* get(Handle h) {
        if (valid(h)) {
            return &slots_[h.index].data;
        }
        return nullptr;
    }

    bool valid(Handle h) const {
        return h.index < slots_.size() &&
               slots_[h.index].occupied &&
               slots_[h.index].generation == h.generation;
    }
};
```

### Pattern 4: Event-Based Communication

Decouple with events instead of direct references:

```cpp
class EventBus {
    using Handler = std::function<void(const Event&)>;
    std::unordered_multimap<std::type_index, Handler> handlers_;

public:
    template<typename E>
    void subscribe(std::function<void(const E&)> handler) {
        handlers_.emplace(
            std::type_index(typeid(E)),
            [handler](const Event& e) {
                handler(static_cast<const E&>(e));
            }
        );
    }

    template<typename E>
    void publish(const E& event) {
        auto [begin, end] = handlers_.equal_range(std::type_index(typeid(E)));
        for (auto it = begin; it != end; ++it) {
            it->second(event);
        }
    }
};

// Usage: No direct references between objects
class Player {
    EventBus& bus_;
public:
    void takeDamage(int amount) {
        health_ -= amount;
        bus_.publish(PlayerDamaged{id_, amount, health_});
    }
};

class UI {
    EventBus& bus_;
public:
    UI(EventBus& bus) : bus_(bus) {
        bus_.subscribe<PlayerDamaged>([this](const PlayerDamaged& e) {
            updateHealthBar(e.playerId, e.health);
        });
    }
};
```

## Safe Observer Pattern

```cpp
class SafeSubject : public std::enable_shared_from_this<SafeSubject> {
    std::vector<std::weak_ptr<SafeObserver>> observers_;

public:
    void attach(std::shared_ptr<SafeObserver> o) {
        observers_.push_back(o);
    }

    void notify() {
        // Clean up dead observers and notify live ones
        observers_.erase(
            std::remove_if(observers_.begin(), observers_.end(),
                [](const auto& weak) { return weak.expired(); }),
            observers_.end()
        );

        for (auto& weak : observers_) {
            if (auto observer = weak.lock()) {
                observer->update();
            }
        }
    }
};

class SafeObserver : public std::enable_shared_from_this<SafeObserver> {
    std::weak_ptr<SafeSubject> subject_;

public:
    void observe(std::shared_ptr<SafeSubject> subject) {
        subject_ = subject;
        subject->attach(shared_from_this());
    }

    virtual void update() = 0;
};
```

## Guidelines

### 1. Make Ownership Explicit

```cpp
// Clear ownership with types
std::unique_ptr<T>     // I own this exclusively
std::shared_ptr<T>     // We share ownership
std::weak_ptr<T>       // I can observe but don't own
T*                     // Non-owning, nullable
T&                     // Non-owning, non-null
std::optional<T>       // I may or may not have this value
```

### 2. Prefer Value Semantics

```cpp
// BAD: Pointer relationship
class Container {
    std::vector<Item*> items_;
};

// GOOD: Value relationship
class Container {
    std::vector<Item> items_;
};
```

### 3. Use Indices for Internal Relationships

```cpp
// BAD: Pointers within same container
class Tree {
    struct Node {
        Node* parent;          // Invalidated on reallocation!
        std::vector<Node*> children;
    };
    std::vector<Node> nodes_;
};

// GOOD: Indices
class Tree {
    struct Node {
        size_t parent;         // Stable
        std::vector<size_t> children;
    };
    std::vector<Node> nodes_;
};
```

### 4. Document Lifetime Requirements

```cpp
/// Process the data.
/// @param data Non-null pointer to data. Caller retains ownership.
///             Must remain valid for the duration of the call.
void process(const Data* data);

/// Store a reference to the context.
/// @param ctx Context that must outlive this object.
class Processor {
public:
    explicit Processor(Context& ctx);  // Reference = must outlive
};
```

### 5. Consider Relationship Cardinality

```cpp
// One-to-one: composition or unique_ptr
class Car {
    std::unique_ptr<Engine> engine_;  // Exactly one
};

// One-to-many: container
class Department {
    std::vector<Employee> employees_;  // Zero or more
};

// Many-to-many: separate relationship table
class Enrollment {
    StudentId student;
    CourseId course;
};
std::vector<Enrollment> enrollments_;
```

## Anti-Patterns

### Circular References

```cpp
// BAD: Memory leak
class Node {
    std::shared_ptr<Node> parent_;
    std::vector<std::shared_ptr<Node>> children_;
};

// GOOD: Break cycle with weak_ptr
class Node {
    std::weak_ptr<Node> parent_;
    std::vector<std::shared_ptr<Node>> children_;
};
```

### Unclear Ownership

```cpp
// BAD: Who owns this?
class Manager {
    std::vector<Widget*> widgets_;  // Owning? Non-owning?
};

// GOOD: Ownership clear
class Manager {
    std::vector<std::unique_ptr<Widget>> widgets_;  // Owning
    // or
    std::vector<Widget*> widget_refs_;  // Non-owning (name suggests it)
};
```

### Hidden Dependencies

```cpp
// BAD: Hidden relationship
void process(Widget& w) {
    auto& parent = getParent(w);  // Where does parent come from?
    // ...
}

// GOOD: Explicit relationship
void process(Widget& w, Container& parent) {
    // Relationship explicit in signature
}
```

## References

### Primary Sources

- **[Better Code: Relationships (YouTube)](https://www.youtube.com/watch?v=ejF6qqohp3M)** — CppCon 2019
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2019-09-19-relationships/2019-09-19-relationships.pdf)**
- **[ACCU 2021 Version (YouTube)](https://www.youtube.com/watch?v=f5UsHQW7-9w)**

### Related Talks

- **Better Code: Data Structures** — Container choice affects relationships
- **Value Semantics and Concept-based Polymorphism** — Avoiding inheritance relationships

---

_"Every time you have a pointer in your code, you have a relationship. Make sure you understand what that relationship is."_ — Sean Parent
