// M0 feasibility experiment. The attribute cast is deliberately under test.
module bridge;

alias Handler = int function(ref State, int) @safe nothrow @nogc;
alias PureHandler = int function(ref State, int) @safe pure nothrow @nogc;

version (InlineBridge)
    enum inlineBridge = true;
else
    enum inlineBridge = false;

struct State
{
    int calls;
    bool stopped;
}

struct Row
{
    @disable this();
    @disable this(this);

    private State* state;
    private Handler handler;

    private this(State* state, Handler handler) @safe nothrow @nogc
    {
        this.state = state;
        this.handler = handler;
    }

    pragma(inline, inlineBridge)
    int call(int input) @safe pure nothrow @nogc
    {
        if (state.stopped)
            return -1;
        auto invoke = (() @trusted pure nothrow @nogc
            => cast(PureHandler) handler)();
        return invoke(*state, input);
    }

    void stop() @safe pure nothrow @nogc
    {
        state.stopped = true;
    }
}

Row makeRow(ref State state, Handler handler) @system nothrow @nogc
{
    return Row(&state, handler);
}

version (DirectImpure)
int forbidden(ref State state, Handler handler) @safe pure nothrow @nogc
{
    return handler(state, 1);
}
