#!/usr/bin/env dub
/+ dub.sdl:
    name "collie_channel"
    dependency "collie" path=".deps/collie"
    dependency "kiss" path=".deps/kiss"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sync.semaphore : Semaphore;
import core.thread : Thread;
import core.time : msecs;
import std.stdio : writeln;

// In collie/Netty, bounded backpressure without fibers requires explicit
// synchronization (e.g. semaphores or watermark events) around a shared buffer.
final class BoundedQueue(T, size_t Capacity)
{
    private T[Capacity] _items;
    private size_t _head;
    private size_t _tail;
    private size_t _count;
    private Semaphore _emptySlots;
    private Semaphore _fullSlots;
    private bool _closed;

    this()
    {
        _emptySlots = new Semaphore(Capacity);
        _fullSlots = new Semaphore(0);
    }

    void put(T item)
    {
        _emptySlots.wait();
        synchronized (this)
        {
            _items[_tail] = item;
            _tail = (_tail + 1) % Capacity;
            ++_count;
        }
        _fullSlots.notify();
    }

    void close()
    {
        synchronized (this)
        {
            _closed = true;
        }
        _fullSlots.notify();
    }

    bool take(out T item)
    {
        _fullSlots.wait();
        synchronized (this)
        {
            if (_count == 0 && _closed)
                return false;
            item = _items[_head];
            _head = (_head + 1) % Capacity;
            --_count;
        }
        _emptySlots.notify();
        return true;
    }
}

void main()
{
    runWorker({
        auto queue = new BoundedQueue!(int, 2)();
        auto readyForThird = new Semaphore(0);
        shared int produced;
        import core.atomic : atomicLoad, atomicStore;

        auto producer = new Thread({
            foreach (i; 1 .. 6)
            {
                if (i == 3) readyForThird.notify();
                queue.put(i);
                atomicStore(produced, i);
            }
            queue.close();
    });
    producer.start();
    readyForThird.wait();
    assert(atomicLoad(produced) == 2, "full queue prevents third put from completing");

    int sum = 0;
    int val;
    int expected = 1;
    while (queue.take(val))
    {
        assert(val == expected++);
        sum += val;
    }

    producer.join();

    assert(sum == 15);
    assert(expected == 6 && atomicLoad(produced) == 5);
    writeln("consumed: ", sum);
    });
}

void runWorker(void delegate() work)
{
    import kiss.event;
    import kiss.event.task : newTask;
    import core.thread : Thread;
    auto loop = new EventLoop();
    scope(exit) loop.dispose();
    bool delivered;
    auto worker = new Thread({
        work();
        loop.postTask(newTask({ delivered = true; loop.stop(); }));
    });
    worker.start();
    loop.run();
    worker.join();
    assert(delivered);
}
