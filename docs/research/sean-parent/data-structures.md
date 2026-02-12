# Better Code: Data Structures

> "The goal is: No incidental data structures."

## Overview

Sean Parent's "Better Code: Data Structures" talk addresses how standard library containers are often both misused and underused. Instead of leveraging well-designed containers, applications frequently create "incidental data structures"—ad-hoc arrangements of objects referencing other objects that don't properly model the domain.

> **Definition:** An incidental data structure is a data structure where there is no object representing the structure as a whole.

The key insight is that proper use of containers can greatly simplify code, improve performance, and reduce bugs.

## What Are Incidental Data Structures?

An incidental data structure is one that emerges accidentally rather than being intentionally designed. It typically lacks a "whole" object that manages the "parts."

### The Components of a Data Structure

Sean Parent defines a data structure as:

1. **Values:** The data elements themselves.
2. **Relationships:** A mapping from one set of values to another.

In an incidental data structure, these relationships are often buried inside the values (e.g., a node containing a pointer to its neighbor).

### Why They Are Harmful

1. **Breaks Local Reasoning:** If objects are linked in an "object soup," you cannot reason about one object without understanding the entire graph. You don't know who owns what or what might change when you modify an object.
2. **Prevents Generic Algorithms:** Standard algorithms (like `std::sort`, `std::partition`, or `std::rotate`) operate on ranges and structures. If your data structure is just a collection of pointers, you cannot use these highly optimized, well-tested algorithms.
3. **Broken Whole-Part Relationship:** A proper data structure should be a "whole" that owns its "parts." Incidental structures often have unclear ownership and broken copy/move semantics.

### Example: The Object Graph

```cpp
// BAD: Incidental data structure
class Node {
    std::vector<Node*> children_;
    Node* parent_;
    std::string name_;

public:
    void addChild(Node* child) {
        children_.push_back(child);
        child->parent_ = this;
    }

    void removeChild(Node* child) {
        children_.erase(
            std::remove(children_.begin(), children_.end(), child),
            children_.end()
        );
        child->parent_ = nullptr;
    }

    // Who owns the nodes?
    // What happens on copy?
    // How do we traverse safely while modifying?
};
```

Problems:

- Ownership unclear
- Copy semantics broken
- Easy to create dangling pointers
- Modification during iteration is unsafe
- Hard to serialize/deserialize

### The Solution: Explicit Structure

```cpp
// GOOD: Intentional data structure
class Tree {
    struct Node {
        std::string name;
        std::vector<size_t> children;  // Indices into nodes_
    };

    std::vector<Node> nodes_;
    size_t root_ = 0;

public:
    size_t addNode(const std::string& name) {
        nodes_.push_back({name, {}});
        return nodes_.size() - 1;
    }

    void addChild(size_t parent, size_t child) {
        nodes_[parent].children.push_back(child);
    }

    // Clear ownership
    // Copyable
    // No dangling pointers
    // Easy to serialize
};
```

## Standard Containers: When to Use What

### Sequential Containers

| Container           | Use When                             | Sean's Take                                                                   |
| ------------------- | ------------------------------------ | ----------------------------------------------------------------------------- |
| `std::vector`       | Default choice; random access needed | **The standard.** Use it for almost everything.                               |
| `std::deque`        | Need push_front and push_back        | A "failed" vector. Rarely the right choice unless you need very large chunks. |
| `std::list`         | Need stable iterators/pointers       | **Avoid.** Usually a sign of a bug or poor design. Cache-killer.              |
| `std::forward_list` | Space-constrained, forward only      | Specialized; rarely used.                                                     |
| `std::array`        | Size known at compile time           | Good for fixed-size buffers; zero overhead.                                   |

> "If you have a `std::list`, you probably have a bug." — Sean Parent (Hyperbole to emphasize that stability is rarely worth the performance cost).

### Associative Containers

| Container            | Use When                           | Avoid When             |
| -------------------- | ---------------------------------- | ---------------------- |
| `std::map`           | Need ordered keys, balanced tree   | Need fastest lookup    |
| `std::set`           | Unique ordered elements            | Don't need ordering    |
| `std::multimap`      | Multiple values per key, ordered   | Single value per key   |
| `std::unordered_map` | Fastest lookup, no ordering needed | Need ordered iteration |
| `std::unordered_set` | Fast unique element lookup         | Need ordering          |

### Container Adapters

| Adapter               | Use When                    |
| --------------------- | --------------------------- |
| `std::stack`          | LIFO semantics              |
| `std::queue`          | FIFO semantics              |
| `std::priority_queue` | Need highest/lowest element |

## Vector Is Almost Always Right

Sean Parent emphasizes that `std::vector` is the right choice most of the time:

### Why Vector?

1. **Cache-friendly**: Contiguous memory
2. **Predictable**: Simple mental model
3. **Fast iteration**: Best for linear scans
4. **Good amortized insertion**: At the end

### Vector for Everything?

Even for operations that seem to favor other containers:

```cpp
// "But I need O(1) deletion in the middle!"
// Actually, for small N, vector is often faster

// Vector with move-to-back-and-pop
template<typename T>
void fast_erase(std::vector<T>& v, typename std::vector<T>::iterator it) {
    *it = std::move(v.back());
    v.pop_back();
}
// O(1) but changes order

// Or use remove-erase idiom
v.erase(std::remove(v.begin(), v.end(), value), v.end());
// O(n) but maintains order and still fast for small N
```

### When Not Vector

- Need stable iterators/pointers after insertion
- Need ordered or hashed lookup
- Size exceeds available contiguous memory
- Frequent insertion/deletion in middle with large N

## Flat Containers

Sean Parent advocates for "flat" containers that store data contiguously:

### Flat Map

```cpp
// Instead of std::map<K, V> (tree-based)
// Use sorted vector + binary search

template<typename K, typename V>
class FlatMap {
    std::vector<std::pair<K, V>> data_;

public:
    void insert(K key, V value) {
        auto it = std::lower_bound(data_.begin(), data_.end(), key,
            [](const auto& p, const K& k) { return p.first < k; });
        data_.insert(it, {std::move(key), std::move(value)});
    }

    V* find(const K& key) {
        auto it = std::lower_bound(data_.begin(), data_.end(), key,
            [](const auto& p, const K& k) { return p.first < k; });
        if (it != data_.end() && it->first == key) {
            return &it->second;
        }
        return nullptr;
    }
};

// Benefits:
// - Cache-friendly iteration
// - Less memory overhead
// - Fast for read-heavy workloads
```

### When Flat vs Tree-Based

| Operation | Flat (sorted vector) | Tree (std::map)          |
| --------- | -------------------- | ------------------------ |
| Lookup    | O(log n)             | O(log n)                 |
| Insert    | O(n)                 | O(log n)                 |
| Iteration | Very fast (cache)    | Slower (pointer chasing) |
| Memory    | Compact              | Overhead per node        |

Use flat containers when:

- Read-heavy, write-light workload
- Need fast iteration
- Dataset fits in cache
- Can batch inserts (sort once)

## Modeling Relationships

Relationships should be handled by the container (the "Whole"), not by the individual elements.

### One-to-Many: Parent-Child

```cpp
// BAD: Pointers (Incidental)
class Parent {
    std::vector<Child*> children_; // Unclear ownership
};

// GOOD: Indices or IDs managed by a Registry
class Registry {
    std::vector<Parent> parents_;
    std::vector<Child> children_;
    std::vector<std::vector<size_t>> parent_to_children_;  // parent index -> child indices
};

// BETTER: Explicit Hierarchy Container
// Use adobe::forest for general tree structures.
// It provides a single "Whole" object that manages all node relationships.
class Tree {
    struct Node {
        Data data;
        size_t parent;
        size_t first_child;
        size_t next_sibling;
    };
    std::vector<Node> nodes_; // All nodes owned by the Tree
};
```

### Relationships as First-Class Citizens

In complex systems, relationships are data too. Don't hide them inside objects.

### Many-to-Many: Relationships

```cpp
// BAD: Each object tracks its relationships
class Student {
    std::vector<Course*> courses_;
};
class Course {
    std::vector<Student*> students_;
};

// GOOD: Separate relationship table
struct Enrollment {
    size_t student_id;
    size_t course_id;
};

class Registry {
    std::vector<Student> students_;
    std::vector<Course> courses_;
    std::vector<Enrollment> enrollments_;  // Explicit relationship

    // Can index for fast lookup
    std::unordered_multimap<size_t, size_t> student_to_courses_;
    std::unordered_multimap<size_t, size_t> course_to_students_;
};
```

### Entity-Component-System (ECS)

```cpp
// For game/simulation with many entities and components

class World {
    // Components stored contiguously by type
    std::vector<Position> positions_;
    std::vector<Velocity> velocities_;
    std::vector<Sprite> sprites_;

    // Entity is just an index + bitmask of components
    struct Entity {
        size_t id;
        std::bitset<NumComponentTypes> components;
    };
    std::vector<Entity> entities_;

    // Systems iterate over components
    void updatePhysics() {
        // Process all entities with Position and Velocity
        for (size_t i = 0; i < entities_.size(); ++i) {
            if (entities_[i].components[Position] &&
                entities_[i].components[Velocity]) {
                positions_[i] += velocities_[i] * dt;
            }
        }
    }
};
```

## Generic Algorithms and Data Structures

A major benefit of avoiding incidental data structures is the ability to use **Generic Algorithms**.

- **Range-based:** Most C++ algorithms operate on ranges (`[begin, end)`). If your structure isn't a range (or a collection of ranges), you can't use them.
- **Complexity Guarantees:** Standard algorithms come with strict complexity guarantees. Incidental structures often lead to accidental O(n²) or worse because of pointer chasing.
- **Reusability:** By using `std::vector` or `adobe::forest`, you can use `std::sort`, `std::partition`, `std::lower_bound`, etc., without writing custom traversal logic.

### Stability: Property of Algorithms

Sean Parent often notes that **stability** is a property of an algorithm (e.g., `std::stable_sort`), but it is enabled by the data structure's properties (like iterator stability or random access). When choosing a data structure, consider whether you need to maintain the relative order of elements during operations.

## Guidelines

### 1. Start with Vector

```cpp
// Default choice
std::vector<Item> items;

// Only switch if you have a specific need:
// - Need fast lookup by key? -> unordered_map
// - Need ordering by key? -> map or sorted vector
// - Need stable iterators? -> adobe::forest or similar (but consider indices first)
```

### 2. Ensure Local Reasoning

Ask yourself: "If I modify this object, what else in the system might change?" If the answer is "I don't know because of pointers," you have an incidental data structure. Use a "Whole" object to manage the scope of change.

### 3. Separate Data from Relationships

```cpp
// BAD: Data intertwined with relationships (Incidental)
class Node {
    Data data;
    Node* parent;
    std::vector<Node*> children;
};

// GOOD: Data and relationships separate (Non-incidental)
struct NodeData {
    Data data;
};

struct NodeRelationship {
    size_t parent;
    std::vector<size_t> children;
};

class Tree {
    std::vector<NodeData> data_;
    std::vector<NodeRelationship> relationships_;
};
```

### 4. Use Indices Instead of Pointers

Indices are stable across copies and moves of the container, whereas pointers are not. They also make serialization trivial.

### 5. Favor "Whole" Objects

Every collection of objects should be owned by a "Whole" object that defines the structure's invariants and provides a clean interface.

## Anti-Patterns

### The Object Soup

The most common incidental data structure. A graph of objects connected by raw or smart pointers with no clear owner and no way to operate on the collection as a unit.

### Hidden Relationships

Relationships modeled as member variables within the data objects themselves, making it impossible to change the structure without changing the data.

### Wrong Container Choice

```cpp
// BAD: Using list for random access
std::list<int> data;
// ...
auto it = data.begin();
std::advance(it, index);  // O(n)!

// GOOD: Use vector
std::vector<int> data;
data[index];  // O(1)
```

### Premature Optimization with Maps

```cpp
// BAD: Assuming map is always right
std::map<int, Value> lookup;  // Only 20 elements

// GOOD: Vector might be faster for small N
std::vector<std::pair<int, Value>> lookup;
// Sort once, binary search
```

## Benchmark Your Choices

Always measure with realistic data:

```cpp
#include <chrono>

template<typename F>
double benchmark(F&& f, int iterations = 1000) {
    auto start = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < iterations; ++i) {
        f();
    }
    auto end = std::chrono::high_resolution_clock::now();
    return std::chrono::duration<double, std::milli>(end - start).count() / iterations;
}

void compareContainers() {
    // Test with your actual data size and access pattern
    auto vec_time = benchmark([&] { vectorLookup(); });
    auto map_time = benchmark([&] { mapLookup(); });

    std::cout << "Vector: " << vec_time << "ms\n";
    std::cout << "Map: " << map_time << "ms\n";
}
```

## References

### Primary Sources

- **[Better Code: Data Structures (YouTube)](https://www.youtube.com/watch?v=sWgDk-o-6ZE)** — CppCon 2015
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2015-09-23-data-structures/data-structures.pdf)**

### Related Talks

- **Better Code: Relationships** — Managing object connections
- **C++ Seasoning** — No incidental data structures

### Further Reading

- **[CppCon 2014: Chandler Carruth "Efficiency with Algorithms, Performance with Data Structures"](https://www.youtube.com/watch?v=fHNmRkzxHWs)**
- **[Data-Oriented Design Resources](https://dataorienteddesign.com/)**

---

_"The first step to better data structures is to stop thinking about individual objects and start thinking about collections of objects."_ — Sean Parent
