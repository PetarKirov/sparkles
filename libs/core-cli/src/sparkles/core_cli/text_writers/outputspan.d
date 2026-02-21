/**
 * Output span tracking for contiguous output ranges.
 *
 * Provides `OutputSpan` for describing written regions and `OutputSpanWriter`
 * for wrapping output ranges with automatic span tracking.
 */
module sparkles.core_cli.text_writers.outputspan;

import std.range.primitives : ElementType, hasLength, isOutputRange;

import sparkles.core_cli.text_writers.traits : hasDataSlice, hasDirectSlice, isContiguousOutputRange;

// ─────────────────────────────────────────────────────────────────────────────
// Output Span Tracking
// ─────────────────────────────────────────────────────────────────────────────

/// Offset/length span describing data written to a contiguous output range.
///
/// The `offset` is meaningful only for output ranges that expose a stable
/// length (e.g., `SmallBuffer` or `Appender`). For output ranges without a
/// length property, spans report an offset of `0` and should be treated as
/// length-only results.
struct OutputSpan
{
    size_t offset;
    size_t length;

    @safe pure nothrow @nogc
    bool empty() const => length == 0;

    @safe pure nothrow @nogc
    size_t end() const => offset + length;

    /// Returns a slice of `w` corresponding to this span.
    @safe pure nothrow @nogc
    auto opIndex(Writer)(ref Writer w) const
    if (isContiguousOutputRange!(Writer, ElementType!Writer))
    {
        return spanSlice(w, this);
    }
}

@safe pure nothrow @nogc
package(sparkles.core_cli.text_writers) size_t outputSpanStart(Writer)(ref Writer w)
{
    static if (hasLength!Writer)
        return w.length;
    else
        return 0;
}

@safe pure nothrow @nogc
package(sparkles.core_cli.text_writers) auto spanSlice(Writer)(ref Writer w, OutputSpan span)
if (isContiguousOutputRange!(Writer, ElementType!Writer))
{
    static if (hasDirectSlice!Writer)
        return w[span.offset .. span.offset + span.length];
    else
        return w.data[span.offset .. span.offset + span.length];
}

/// Output range wrapper that tracks the span written through it.
struct OutputSpanWriter(Writer)
{
    private Writer* writer;
    size_t start;
    size_t cursor;

    @safe
    this(ref Writer writer)
    {
        this.writer = &writer;
        start = outputSpanStart(writer);
        cursor = start;
    }

    @safe
    @property size_t length() const scope
    {
        static if (hasLength!Writer)
            return (*writer).length;
        else
            return cursor;
    }

    @safe
    void put(char value) scope
    {
        import std.range.primitives : put;
        put(*writer, value);
        cursor += 1;
    }

    @safe
    void put(const(char)[] values) scope
    {
        import std.range.primitives : put;
        put(*writer, values);
        cursor += values.length;
    }

    @safe
    OutputSpan release() const scope =>
        OutputSpan(start, length - start);
}

/// Copies data described by `span` from `src` into `dest`.
@safe pure nothrow @nogc
void copySpan(Dest, Src)(ref Dest dest, ref Src src, OutputSpan span)
if (isOutputRange!(Dest, ElementType!Src) && isContiguousOutputRange!(Src, ElementType!Src))
{
    import std.range.primitives : put;

    put(dest, spanSlice(src, span));
}
