# Better Code: Relationships

> "Computer scientists are bad at relationships."

## Overview

Sean Parent's "Better Code: Relationships" talk addresses the most common source of software defects: mismanaged connections between entities. While developers focus heavily on types and functions, it is the _relationships_ between objects that typically cause crashes, leaks, and logic errors.

A **Relationship** is formally defined as a set of ordered pairs mapping entities from a domain to a range.

- **Functional Relationship**: A relationship where each element in the domain maps to exactly one element in the range (i.e., a function).
- **General Relationship**: A relationship where an element in the domain can map to zero, one, or many elements in the range (e.g., "is a friend of").

### The Primary Relationship: Equality

Sean Parent argues that **Equality** (and by extension, **Identity**) is the most fundamental relationship. All other relationships are defined by how they interact with equality. If two objects are equal, they should be substitutable in any relationship without changing the truth of that relationship (Leibniz's Law).

## Incidental Data Structures

An **Incidental Data Structure** is a data structure formed by the pointers and references between objects that was not intentionally designed as a coherent structure.

### Example: The Observer Pattern Gone Wrong

The classic observer pattern is a prime example of an incidental data structure. It creates a hidden, complex web of dependencies that are difficult to manage.

```cpp
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
    virtual ~Observer() { subject_->detach(this); }  // What if subject_ was destroyed first?
    virtual void update() = 0;
};
```

- **Symptoms**: Use of `std::shared_ptr` to "solve" lifetime issues, back-pointers (parent pointers) in nodes, and complex webs of observers.
- **Problem**: They break local reasoning. You cannot modify one object without potentially affecting an unknown number of other objects connected through the "web."
- **Solution**: Replace incidental structures with **Intended Data Structures** (like a `std::vector` or a `stlab::forest`) and model relationships explicitly.

## The Whole-Part Relationship

The "Whole-Part" relationship is the foundation for building complex objects from simpler ones. For a relationship to be a true Whole-Part relationship, it must satisfy three properties:

1.  **Non-Circular**: A part cannot contain its whole. The relationship must form a Directed Acyclic Graph (DAG) or, ideally, a tree.
2.  **Logically Disjoint**: Parts are not shared between different wholes. If you have two "whole" objects, their parts should not overlap. (Note: This refers to mutable state; immutable state may be shared safely).
3.  **Owning**: The lifetime of the part is strictly contained within the lifetime of the whole. When the whole is destroyed, the parts are destroyed.

**Value Semantics** are the cleanest way to implement Whole-Part relationships. If an object is a member variable, it is naturally non-circular, logically disjoint, and owned.

## Relationship Attributes

To model a relationship correctly, one must define its attributes:

- **Directionality**: Is the relationship unidirectional (A knows B) or bidirectional (A and B know each other)? Bidirectional relationships are harder to maintain and often lead to cycles.
- **Cardinality**: How many entities are involved? (One-to-One, One-to-Many, Many-to-Many).
- **Optionality**: Is the relationship required or optional (nullable)?
- **Durability**: Does the relationship persist (e.g., saved to disk) or is it transient (only in memory)?
- **Ordering**: Is there a specific order to the related entities?

## Representing Relationships

Sean Parent identifies four primary ways to represent a relationship in code, in order of preference:

### 1. Value (Composition)

The part is physically contained within the whole.

- **Pros**: Best for local reasoning, automatic lifetime management, cache-friendly.
- **Cons**: Fixed at compile-time, size increases.

```cpp
struct Car {
    Engine engine_; // Clear Whole-Part relationship
};
```

### 2. Identity (Indices/Handles/Keys)

Objects are stored in a flat structure (like a `std::vector` or `SlotMap`), and relationships are represented by indices or unique IDs.

- **Pros**: Breaks physical cycles, stable across reallocations, supports persistence, easy to "tableify."
- **Cons**: Requires a context (the container) to resolve the handle.

```cpp
// BAD: Pointers within same container (invalidated on reallocation)
struct Node {
    Node* parent;
    std::vector<Node*> children;
};

// GOOD: Indices (Stable, memory-safe, serializable)
struct Node {
    static constexpr size_t npos = -1;
    size_t parent_index = npos; // Use sentinel for 'no parent'
    std::vector<size_t> children;
};
```

### 3. Reference (Pointers)

A direct memory address.

- **Pros**: Fast, low-level.
- **Cons**: Very dangerous. Leads to incidental data structures, dangling pointers, and "use-after-free" bugs. Pointers do not communicate ownership.

### 4. Container

A specialized object whose sole purpose is to manage a relationship (e.g., `std::map`, `std::vector`).

## Explicit vs. Implicit Relationships

- **Implicit**: The relationship is buried in the structure of the objects (e.g., a linked list where `next` pointers define the sequence).
- **Explicit**: The relationship is a first-class entity (e.g., a separate `std::vector<Edge>` in a graph).

**Parent's Guidance**: Move towards explicit relationships. When a relationship is explicit, you can apply algorithms to it directly.

## Relationship Management Patterns

### Pattern 1: Slot Map (Stable Identity)

Uses generation counters to ensure handles are never stale even if the underlying memory is reused. This pattern transforms a "Reference" relationship into a "Stable Identity" relationship.

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
        slots_[index] = {std::move(value), slots_[index].generation, true};
        return {index, slots_[index].generation};
    }

    void erase(Handle h) {
        if (valid(h)) {
            slots_[h.index].occupied = false;
            slots_[h.index].generation++;
            free_list_.push_back(h.index);
        }
    }

    bool valid(Handle h) const {
        return h.index < slots_.size() &&
               slots_[h.index].occupied &&
               slots_[h.index].generation == h.generation;
    }

    T* get(Handle h) { return valid(h) ? &slots_[h.index].data : nullptr; }
};
```

### Pattern 2: Registry / Relationship Table

Instead of objects pointing to each other, a central registry tracks who is related to whom. This mirrors how relational databases work.

```cpp
class RelationshipTable {
    std::unordered_multimap<PersonId, PersonId> is_friend_of;

public:
    void addFriendship(PersonId a, PersonId b) {
        is_friend_of.emplace(a, b);
        is_friend_of.emplace(b, a); // Bidirectional explicit management
    }
};
```

### Pattern 3: The "Safe" Observer (Avoiding the Web)

Classic observer patterns create complex incidental data structures. Even "safe" observers (using `std::weak_ptr`) still represent a hidden web of dependencies.

**Parent's Preferred Alternatives**:

1.  **Registry**: Centralize the relationship in a single object that manages notifications.
2.  **Value-based Notification**: Use a system where state changes are communicated via values (events) rather than callbacks into objects.
3.  **Explicit Relationship Table**: Store the observer-subject relationship in a separate data structure.

## Anti-Patterns

### 1. The `shared_ptr` Web

Using `shared_ptr` for everything is a sign that relationships are not understood. It often creates a graph where no one knows who owns what, leading to leaks (if there are cycles) or delayed destruction.

### 2. Parent Pointers

Pointers from a child back to its parent break the "Non-Circular" property of Whole-Part relationships. If you need to navigate up, pass the parent as a parameter to the function or use a stable identity (index).

### 3. Hidden Coupling

Functions that reach through multiple layers of relationships (e.g., `a->b()->c()->doSomething()`) violate the Law of Demeter and break local reasoning.

## Summary Checklist for Relationships

1.  Is this a **Whole-Part** relationship? (Check: Non-circular, Logically Disjoint, Owning).
2.  Can I use **Value Semantics** instead of pointers?
3.  If I need a reference, can I use an **Index** or **Handle** (Identity) instead of a pointer?
4.  Is the **Directionality** minimal? (Prefer unidirectional).
5.  Is the relationship **Explicitly** modeled so I can run algorithms on it?

---

## References

### Primary Sources

- **[Better Code: Relationships (YouTube)](https://www.youtube.com/watch?v=ejF6qqohp3M)** — CppCon 2019
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2019-09-19-relationships/2019-09-19-relationships.pdf)**
- **[ACCU 2021 Version (YouTube)](https://www.youtube.com/watch?v=f5UsHQW7-9w)**

### Related Concepts

- **[Local Reasoning](local-reasoning.md)**
- **[Value Semantics](value-semantics.md)**
- **[Data Structures](data-structures.md)**

---

_"Every time you have a pointer in your code, you have a relationship. Make sure you understand what that relationship is."_ — Sean Parent
