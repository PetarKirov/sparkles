module doc_coverage.internal.private_bits;

private int hiddenCount;

/// Helper only used for exclusion and privacy tests.
private int hiddenIncrement()
{
    return ++hiddenCount;
}

@("docCoverage.internal.privateBits")
@safe
unittest
{
    assert(hiddenIncrement() == 1);
}
