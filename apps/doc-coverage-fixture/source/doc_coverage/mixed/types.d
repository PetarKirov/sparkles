module doc_coverage.mixed.types;

/// Strongly typed player id.
struct PlayerId
{
    int value;
}

/// Public alias for callback shape.
alias TickCallback = int delegate(int ticks);

/// Optional callback holder.
TickCallback activeTickCallback;

int invokeTick(int ticks)
{
    if (activeTickCallback is null)
        return ticks;
    return activeTickCallback(ticks);
}

@("docCoverage.mixed.types.invokeTick")
@safe
unittest
{
    activeTickCallback = (int t) => t + 1;
    assert(invokeTick(4) == 5);
}
