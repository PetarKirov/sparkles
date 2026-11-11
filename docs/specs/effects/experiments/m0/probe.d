// M0: normal calls, discarded calls, aliases, control and ambient state.
module probe;

import bridge : Row, State, makeRow;
import core.stdc.stdio : printf;

int worldCalls;
Exception preparedException;

int throwsPrepared(ref State state, int input) @safe @nogc
{
    throw preparedException;
}

int translateException(ref State state, int input) @safe nothrow @nogc
{
    try
        return throwsPrepared(state, input);
    catch (Exception e)
    {
        state.stopped = true;
        return -2;
    }
}

version (ThrowingHandler)
{
    import bridge : Handler;
    Handler badHandler = &throwsPrepared;
}

version (AllocatingHandler)
{
    import bridge : Handler;
    int allocates(ref State state, int input) @safe nothrow;
    Handler badHandler = &allocates;
}

// A minimal explicit schema allowlist, not a production codec or a purity trait.
enum recordable(T) = is(T == int);
void encode(T)(in T value) if (recordable!T) {}

version (SerializeResource)
void badSerialization(ref Row row)
{
    encode(row);
}

int live(ref State state, int input) @safe nothrow @nogc
{
    ++state.calls;
    ++worldCalls;
    (() @trusted nothrow @nogc { printf("effect:%d\n", input); })();
    return input + state.calls;
}

int body(ref Row row, in int input) @safe pure nothrow @nogc
{
    const first = row.call(input);
    const second = row.call(input);
    row.call(input); // discarded result must still execute
    ref Row aliasRow() @safe pure nothrow @nogc { return row; }
    const fourth = aliasRow().call(input);
    row.stop();
    const stopped = row.call(input);
    assert(stopped == -1);
    return first + second + fourth;
}

// This is permitted by weak purity: the callback mutates its captured context.
int invokeContext(scope int delegate() @safe pure nothrow @nogc dg)
    @safe pure nothrow @nogc
{
    return dg() + dg();
}

version (AmbientClock)
int badClock() @safe pure nothrow @nogc
{
    import core.time : MonoTime;
    return cast(int) MonoTime.currTime.ticks;
}

version (AmbientIo)
void badIo() @safe pure nothrow @nogc
{
    import std.stdio : writeln;
    writeln("ambient I/O");
}

version (EscapeHandler)
auto badEscape(ref Row row) @safe pure nothrow @nogc
{
    return row.handler;
}

version (CopyRow)
void badCopy(ref Row row) @safe pure nothrow @nogc
{
    auto copy = row;
}

version (DebugEscape)
void debugEscape() @safe pure nothrow @nogc
{
    debug ++worldCalls;
}

int main() @system
{
    State firstState;
    auto firstRow = makeRow(firstState, &live);
    const a = body(firstRow, 10);
    State secondState;
    auto secondRow = makeRow(secondState, &live);
    const b = body(secondRow, 10);
    int captured;
    auto dg = delegate int() @safe pure nothrow @nogc { return ++captured; };
    const contextResult = invokeContext(dg);
    printf("a=%d b=%d local=%d,%d world=%d context=%d,%d\n",
        a, b, firstState.calls, secondState.calls, worldCalls,
        contextResult, captured);
    assert(a == 37 && b == 37);
    assert(firstState.calls == 4 && secondState.calls == 4);
    assert(worldCalls == 8);
    assert(contextResult == 3 && captured == 2);
    preparedException = new Exception("prepared outside the no-GC handler");
    State exceptionState;
    auto exceptionRow = makeRow(exceptionState, &translateException);
    const translated = exceptionRow.call(0);
    const latched = exceptionRow.call(0);
    printf("exception=%d latched=%d\n", translated, latched);
    assert(translated == -2 && latched == -1);
    version (DebugEscape)
    {
        debugEscape();
        printf("debug-world=%d\n", worldCalls);
    }
    return 0;
}
