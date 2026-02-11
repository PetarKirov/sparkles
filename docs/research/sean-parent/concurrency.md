# Better Code: Concurrency

> "The goal of concurrent code is to write software that doesn't wait."

## Overview

Sean Parent's "Better Code: Concurrency" talks present a task-based approach to concurrent programming that avoids the pitfalls of raw threads and synchronization primitives. Instead of thinking about threads, locks, and shared state, this approach focuses on tasks, futures, and continuations.

The key insight is that concurrency should be about _what_ operations need to happen and their dependencies, not _how_ threads are managed.

## Why Concurrency?

There are two primary reasons to write concurrent code:

### 1. Performance (Parallelism)

Use multiple CPU cores to complete work faster:

```cpp
// Sequential: ~10 seconds
for (int i = 0; i < 10; ++i) {
    expensive_operation(i);  // 1 second each
}

// Parallel: ~2 seconds (on 5+ cores)
std::vector<std::future<void>> futures;
for (int i = 0; i < 10; ++i) {
    futures.push_back(std::async(std::launch::async, expensive_operation, i));
}
for (auto& f : futures) f.get();
```

### 2. Responsiveness (Interactivity)

Keep the UI responsive while doing work:

```cpp
// BAD: UI freezes during operation
void onButtonClick() {
    auto result = expensive_operation();  // UI blocked!
    display(result);
}

// GOOD: UI stays responsive
void onButtonClick() {
    auto future_result = std::async(std::launch::async, expensive_operation);
    // UI can continue
    // Later, when result is ready:
    display(future_result.get());
}
```

## The Problems with Raw Concurrency

### Raw Threads

```cpp
// BAD: Manual thread management
std::thread t([&data] {
    // What if data goes out of scope?
    // How do we get results back?
    // Who joins the thread?
    process(data);
});
// Must remember to join or detach
t.join();
```

### Raw Synchronization

```cpp
// BAD: Mutex and condition variable
std::mutex mtx;
std::condition_variable cv;
bool ready = false;
Result result;

std::thread producer([&] {
    result = compute();
    {
        std::lock_guard<std::mutex> lock(mtx);
        ready = true;
    }
    cv.notify_one();
});

std::unique_lock<std::mutex> lock(mtx);
cv.wait(lock, [&] { return ready; });
use(result);
// Easy to deadlock, race, or leak
```

### Problems

1. **Complexity**: Low-level primitives are hard to use correctly
2. **Deadlocks**: Lock ordering, forgotten unlocks
3. **Data races**: Shared mutable state
4. **Resource leaks**: Threads not joined, locks held
5. **No composability**: Can't easily combine concurrent operations

## The Task-Based Solution

### Futures and Promises

Futures represent values that will be available later:

```cpp
// Promise: producer side
std::promise<int> promise;
auto future = promise.get_future();

std::thread producer([&promise] {
    int result = expensive_computation();
    promise.set_value(result);  // Fulfill the promise
});

// Consumer: blocks until ready
int value = future.get();

producer.join();
```

### std::async

Higher-level abstraction that manages threads:

```cpp
// Launch async task
auto future = std::async(std::launch::async, expensive_computation);

// Do other work...

// Get result (blocks if not ready)
int result = future.get();
```

## Continuations: Chaining Operations

The real power comes from chaining operations without blocking.

### The Problem with get()

```cpp
// BAD: Blocking get() defeats the purpose
auto f1 = std::async(step1);
auto r1 = f1.get();  // Block!
auto f2 = std::async([r1] { return step2(r1); });
auto r2 = f2.get();  // Block!
auto f3 = std::async([r2] { return step3(r2); });
auto result = f3.get();  // Block!
```

### Continuations with stlab

Sean Parent's stlab library provides `.then()` for chaining:

```cpp
// GOOD: Continuations (no blocking)
auto result = stlab::async(stlab::default_executor, step1)
    .then([](auto r1) { return step2(r1); })
    .then([](auto r2) { return step3(r2); });

// Only block at the end if needed
auto final_value = stlab::blocking_get(result);
```

### How Continuations Work

```
step1 ──► step2 ──► step3 ──► result
  │         │         │
  └─────────┴─────────┴── Each step runs when predecessor completes
                          No blocking between steps
```

## Building a Task System

Sean Parent demonstrates building a simple task system:

### Thread Pool

```cpp
class TaskSystem {
    std::vector<std::thread> threads_;
    std::deque<std::function<void()>> tasks_;
    std::mutex mutex_;
    std::condition_variable cv_;
    bool stop_ = false;

public:
    TaskSystem(size_t thread_count = std::thread::hardware_concurrency()) {
        for (size_t i = 0; i < thread_count; ++i) {
            threads_.emplace_back([this] { worker(); });
        }
    }

    ~TaskSystem() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stop_ = true;
        }
        cv_.notify_all();
        for (auto& t : threads_) t.join();
    }

    template<typename F>
    void submit(F&& task) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            tasks_.emplace_back(std::forward<F>(task));
        }
        cv_.notify_one();
    }

private:
    void worker() {
        while (true) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait(lock, [this] { return stop_ || !tasks_.empty(); });
                if (stop_ && tasks_.empty()) return;
                task = std::move(tasks_.front());
                tasks_.pop_front();
            }
            task();
        }
    }
};
```

### Futures with Continuations

```cpp
template<typename T>
class Future {
    std::shared_ptr<SharedState<T>> state_;

public:
    T get() {
        std::unique_lock<std::mutex> lock(state_->mutex);
        state_->cv.wait(lock, [this] { return state_->ready; });
        return std::move(state_->value);
    }

    template<typename F>
    auto then(F&& f) -> Future<decltype(f(std::declval<T>()))> {
        using R = decltype(f(std::declval<T>()));
        auto promise = std::make_shared<Promise<R>>();
        auto future = promise->get_future();

        state_->continuations.push_back(
            [p = std::move(promise), f = std::forward<F>(f)](T value) {
                p->set_value(f(std::move(value)));
            }
        );

        return future;
    }
};
```

## Patterns for Concurrent Code

### Fan-Out / Fan-In

Run multiple tasks in parallel, then combine results:

```cpp
// Fan-out: start multiple tasks
auto f1 = stlab::async(executor, task1);
auto f2 = stlab::async(executor, task2);
auto f3 = stlab::async(executor, task3);

// Fan-in: combine when all complete
auto combined = stlab::when_all(executor, f1, f2, f3)
    .then([](auto r1, auto r2, auto r3) {
        return combine(r1, r2, r3);
    });
```

### Pipeline

Process items through a series of stages:

```cpp
// Pipeline: each stage runs concurrently
auto pipeline = stlab::channel<Input>(executor)
    | stage1
    | stage2
    | stage3;

// Feed items into pipeline
for (const auto& item : items) {
    pipeline.send(item);
}
```

### Serial Queue

Ensure operations on shared state are serialized:

```cpp
class SerialQueue {
    TaskSystem& system_;
    std::mutex mutex_;
    std::queue<std::function<void()>> pending_;
    bool running_ = false;

public:
    template<typename F>
    void submit(F&& f) {
        std::lock_guard<std::mutex> lock(mutex_);
        pending_.push(std::forward<F>(f));
        if (!running_) {
            running_ = true;
            system_.submit([this] { process(); });
        }
    }

private:
    void process() {
        while (true) {
            std::function<void()> task;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (pending_.empty()) {
                    running_ = false;
                    return;
                }
                task = std::move(pending_.front());
                pending_.pop();
            }
            task();
        }
    }
};
```

## Guidelines

### 1. Don't Use Raw Threads

```cpp
// BAD
std::thread t(some_work);
t.detach();  // Fire and forget - resource leak

// GOOD
auto future = std::async(std::launch::async, some_work);
// Future ensures completion
```

### 2. Don't Use Raw Synchronization

```cpp
// BAD
std::mutex mtx;
std::condition_variable cv;
// ... complex signaling ...

// GOOD
auto result = async_operation().then(next_operation);
```

### 3. Prefer Immutable Data

```cpp
// BAD: Shared mutable state
std::vector<int> shared_data;
std::mutex data_mutex;

void task() {
    std::lock_guard<std::mutex> lock(data_mutex);
    shared_data.push_back(42);  // Contention!
}

// GOOD: Each task owns its data
auto task(std::vector<int> data) {
    data.push_back(42);
    return data;  // Return new state
}
```

### 4. Use Message Passing

```cpp
// Instead of shared state, pass messages
auto producer = stlab::channel<Message>(executor);
auto consumer = producer | [](Message msg) {
    return process(msg);
};

producer.send(Message{...});
```

### 5. Design for Cancellation

```cpp
// Use cancellation tokens
std::atomic<bool> cancelled{false};

auto task = async([&cancelled] {
    while (!cancelled && work_remaining()) {
        do_chunk_of_work();
    }
});

// Later:
cancelled = true;
```

## Common Pitfalls

### Deadlock

```cpp
// BAD: Lock ordering can deadlock
void transfer(Account& from, Account& to, int amount) {
    std::lock_guard<std::mutex> lock1(from.mutex);
    std::lock_guard<std::mutex> lock2(to.mutex);  // Deadlock if another thread does reverse
    // ...
}

// GOOD: Use std::lock or std::scoped_lock
void transfer(Account& from, Account& to, int amount) {
    std::scoped_lock lock(from.mutex, to.mutex);  // Avoids deadlock
    // ...
}

// BETTER: Don't use locks at all
auto transfer(Account from, Account to, int amount) {
    from.balance -= amount;
    to.balance += amount;
    return std::make_pair(from, to);  // Return new state
}
```

### Data Race

```cpp
// BAD: Unprotected shared access
int counter = 0;
void increment() { ++counter; }  // Data race!

// GOOD: Use atomic
std::atomic<int> counter{0};
void increment() { ++counter; }

// BETTER: Avoid shared state
auto increment(int counter) { return counter + 1; }
```

### Blocking the Main Thread

```cpp
// BAD: UI blocked
void onButton() {
    auto result = long_operation();  // Blocks UI!
    display(result);
}

// GOOD: Async with callback
void onButton() {
    async(long_operation).then([](auto result) {
        runOnMainThread([result] { display(result); });
    });
}
```

## STLab Libraries

Sean Parent's stlab provides production-ready concurrency primitives:

### stlab::future

```cpp
#include <stlab/concurrency/future.hpp>

auto f = stlab::async(stlab::default_executor, [] {
    return expensive_computation();
}).then([](auto result) {
    return transform(result);
});
```

### stlab::channel

```cpp
#include <stlab/concurrency/channel.hpp>

auto [send, receive] = stlab::channel<int>(stlab::default_executor);

receive | [](int x) { process(x); };

send(42);
```

## References

### Primary Sources

- **[Better Code: Concurrency (YouTube)](https://www.youtube.com/watch?v=zULU6Hhp42w)** — NDC London 2017
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2017-01-18-concurrency/2017-01-18-concurrency.pdf)**
- **[C++ Source Code](https://sean-parent.stlab.cc/presentations/2015-02-27-concurrency/concurrency-talk.cpp)**

### STLab Resources

- **[STLab Libraries](https://stlab.cc/libraries/)** — Concurrency library
- **[STLab GitHub](https://github.com/stlab/libraries)** — Source code

### Related Talks

- **Chains: An Alternative to Sender/Receivers** — More recent concurrency work

---

_"The problem with threads is that they make you think about threading. What you really want to think about is tasks and their dependencies."_ — Sean Parent
