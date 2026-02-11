# C++ Seasoning: Three Goals for Better Code

> "No raw loops. No raw synchronization primitives. No raw pointers."

## Overview

"C++ Seasoning" is Sean Parent's landmark presentation from GoingNative 2013 that introduced his three fundamental goals for writing better code. This talk has become one of the most influential C++ presentations, establishing principles that guide modern C++ development.

## The Three Goals

### Goal 1: No Raw Loops

**Principle**: A raw loop is any loop inside a function where the function serves a larger purpose than implementing the algorithm represented by the loop.

#### Why No Raw Loops?

1. **Expresses intent poorly** — Loops describe _how_, not _what_
2. **Error-prone** — Off-by-one errors, iterator invalidation, boundary mistakes
3. **Hard to reason about** — Loop invariants are implicit
4. **Not composable** — Can't easily combine loop logic
5. **Hinders optimization** — Compilers can better optimize known algorithms

#### What To Do Instead

Use standard library algorithms:

```cpp
// BAD: Raw loop to find an element
for (auto i = v.begin(); i != v.end(); ++i) {
    if (*i == target) {
        return i;
    }
}
return v.end();

// GOOD: Use std::find
return std::find(v.begin(), v.end(), target);
```

```cpp
// BAD: Raw loop to transform
std::vector<int> result;
for (const auto& x : input) {
    result.push_back(x * 2);
}

// GOOD: Use std::transform
std::vector<int> result;
std::transform(input.begin(), input.end(),
               std::back_inserter(result),
               [](int x) { return x * 2; });

// BETTER: Use ranges (C++20)
auto result = input | std::views::transform([](int x) { return x * 2; })
                    | std::ranges::to<std::vector>();
```

#### When Raw Loops Are Acceptable

- Implementing a new algorithm that will be reused
- Performance-critical code where measurement shows algorithms are insufficient
- The operation genuinely doesn't map to any existing algorithm

### Goal 2: No Raw Synchronization Primitives

**Principle**: Don't use mutexes, condition variables, semaphores, or other low-level synchronization directly in application code.

#### Why No Raw Synchronization?

1. **Extremely error-prone** — Deadlocks, race conditions, priority inversion
2. **Violates local reasoning** — Must understand global state to reason about correctness
3. **Hard to compose** — Combining locks often leads to deadlocks
4. **Performance pitfalls** — Lock contention, false sharing

#### What To Do Instead

Use higher-level abstractions:

```cpp
// BAD: Raw mutex and condition variable
std::mutex mtx;
std::condition_variable cv;
bool ready = false;

void producer() {
    {
        std::lock_guard<std::mutex> lock(mtx);
        // prepare data
        ready = true;
    }
    cv.notify_one();
}

void consumer() {
    std::unique_lock<std::mutex> lock(mtx);
    cv.wait(lock, []{ return ready; });
    // consume data
}

// GOOD: Use futures and promises
std::promise<Data> promise;
auto future = promise.get_future();

void producer() {
    Data data = prepare_data();
    promise.set_value(std::move(data));
}

void consumer() {
    Data data = future.get();
    // consume data
}

// BETTER: Use task-based concurrency (stlab)
auto result = stlab::async(stlab::default_executor, [] {
    return compute_something();
}).then([](auto value) {
    return process(value);
});
```

#### Preferred Concurrency Patterns

1. **Futures and continuations** — Chain asynchronous operations
2. **Task queues** — Submit work to thread pools
3. **Channels** — Communicate between concurrent tasks
4. **Actors** — Encapsulate state with message passing

### Goal 3: No Raw Pointers (for Ownership)

**Principle**: Raw pointers should not convey ownership semantics. Use smart pointers or values instead.

#### Why No Raw Pointers for Ownership?

1. **Unclear ownership** — Who deletes the memory?
2. **Memory leaks** — Easy to forget to delete
3. **Double deletion** — Multiple owners delete the same memory
4. **Dangling pointers** — Using memory after it's freed
5. **Exception unsafety** — Leaks when exceptions are thrown

#### What To Do Instead

```cpp
// BAD: Raw pointer ownership
Widget* createWidget() {
    return new Widget();
}

void useWidget() {
    Widget* w = createWidget();
    process(w);  // What if this throws?
    delete w;    // Might not be reached
}

// GOOD: Use unique_ptr for exclusive ownership
std::unique_ptr<Widget> createWidget() {
    return std::make_unique<Widget>();
}

void useWidget() {
    auto w = createWidget();
    process(w.get());
    // Automatically deleted
}

// GOOD: Use shared_ptr for shared ownership
std::shared_ptr<Widget> createWidget() {
    return std::make_shared<Widget>();
}

// BEST: Use values when possible
Widget createWidget() {
    return Widget();  // Move semantics make this efficient
}
```

#### When Raw Pointers Are Acceptable

- **Non-owning references** — Pointing to something owned elsewhere
- **Interfacing with C APIs** — External code that requires raw pointers
- **Performance-critical code** — After measurement proves necessity
- **Optional references** — When a reference might be null (though `std::optional` is often better)

## The Slide and Gather Algorithms

Sean Parent introduced two algorithms that demonstrate the power of composition:

### Slide

Move a range of elements to a new position:

```cpp
template<typename I>  // I models BidirectionalIterator
auto slide(I first, I last, I pos) -> std::pair<I, I> {
    if (pos < first) return { pos, std::rotate(pos, first, last) };
    if (last < pos)  return { std::rotate(first, last, pos), pos };
    return { first, last };
}
```

### Gather

Collect elements matching a predicate around a position:

```cpp
template<typename I, typename P>
auto gather(I first, I last, I pos, P pred) -> std::pair<I, I> {
    return {
        std::stable_partition(first, pos, std::not_fn(pred)),
        std::stable_partition(pos, last, pred)
    };
}
```

## Key Algorithms to Know

Sean emphasizes mastering these standard algorithms:

| Algorithm                       | Purpose                 | Complexity       |
| ------------------------------- | ----------------------- | ---------------- |
| `find`, `find_if`               | Locate element          | O(n)             |
| `count`, `count_if`             | Count matches           | O(n)             |
| `transform`                     | Apply function to range | O(n)             |
| `accumulate`, `reduce`          | Fold operation          | O(n)             |
| `partition`, `stable_partition` | Divide by predicate     | O(n), O(n log n) |
| `sort`, `stable_sort`           | Order elements          | O(n log n)       |
| `rotate`                        | Cycle elements          | O(n)             |
| `copy`, `move`                  | Transfer elements       | O(n)             |
| `remove`, `remove_if`           | Prepare for erase       | O(n)             |

## Guidelines

1. **Learn the standard algorithms** — Know what's available before writing loops
2. **Prefer algorithms over loops** — Even if it seems verbose at first
3. **Use ranges** — C++20 ranges make algorithms more composable
4. **Compose existing algorithms** — Build new operations from primitives
5. **Measure before optimizing** — Don't assume algorithms are slower
6. **Use task-based concurrency** — Avoid threads and locks directly
7. **Prefer values to pointers** — Move semantics make this efficient
8. **Use smart pointers for ownership** — `unique_ptr` by default, `shared_ptr` when needed

## Anti-Patterns

### Loop Anti-Patterns

```cpp
// Anti-pattern: Index loop when iterator works
for (size_t i = 0; i < v.size(); ++i) {
    process(v[i]);
}

// Anti-pattern: Manual find
bool found = false;
for (const auto& x : v) {
    if (x == target) {
        found = true;
        break;
    }
}

// Anti-pattern: Accumulate with loop
int sum = 0;
for (const auto& x : v) {
    sum += x;
}
```

### Synchronization Anti-Patterns

```cpp
// Anti-pattern: Global lock
std::mutex global_mutex;
void anyOperation() {
    std::lock_guard<std::mutex> lock(global_mutex);
    // everything serialized
}

// Anti-pattern: Fine-grained locking without deadlock prevention
void transfer(Account& from, Account& to, int amount) {
    std::lock_guard<std::mutex> lock1(from.mutex);  // Deadlock risk!
    std::lock_guard<std::mutex> lock2(to.mutex);
    // ...
}
```

### Pointer Anti-Patterns

```cpp
// Anti-pattern: Returning raw owning pointer
Widget* createWidget();  // Who owns this?

// Anti-pattern: Raw pointer member for ownership
class Container {
    Widget* widget_;  // Leak on destruction?
public:
    ~Container() { delete widget_; }  // Manual cleanup
};

// Anti-pattern: Raw pointer in container
std::vector<Widget*> widgets;  // Who deletes these?
```

## References

### Primary Sources

- **[C++ Seasoning - GoingNative 2013](https://channel9.msdn.com/Events/GoingNative/2013/Cpp-Seasoning)** — Original presentation
- **[C++ Seasoning Slides (PDF)](https://sean-parent.stlab.cc/presentations/2013-09-11-cpp-seasoning/cpp-seasoning.pdf)** — Presentation slides
- **[Extended Version (YouTube)](https://www.youtube.com/watch?v=IzNtM038JuI)** — ACCU Silicon Valley version with extended content

### Related Talks

- **Better Code: Concurrency** — Deep dive on the second goal
- **Better Code: Data Structures** — Using containers instead of raw pointers
- **Better Code: Relationships** — Managing object lifetimes

### Further Reading

- **[C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/)** — Industry guidelines aligned with these principles
- **[STLab Libraries](https://stlab.cc/libraries/)** — Sean Parent's concurrency library

---

_"That's a rotate!"_ — Sean Parent's catchphrase when recognizing the rotate algorithm in disguise
