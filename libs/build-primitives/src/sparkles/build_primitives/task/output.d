/++
Per-task output spooling ([SPEC TDM14, TDO3](../../../../../../docs/specs/build-primitives/task-dag/SPEC.md)):
a task's output lines are kept in memory up to a byte budget; past it the
whole transcript continues in a spill file, and memory keeps only the most
recent lines — the diagnostic tail.

The spill file is line-oriented: each line is a one-byte stream tag (`o`
stdout, `e` stderr; upper case for an unterminated final fragment), a space,
and the text, with `\` written `\\`, a line feed `\n`, and a carriage return
`\r`, so a record is always one line. $(LREF OutputSpool.replay) reads it back, so a spilled
transcript replays exactly like an in-memory one.
+/
module sparkles.build_primitives.task.output;

import std.stdio : File;

import sparkles.build_primitives.task.model : OutputStream;

/// One spooled line.
struct SpooledLine
{
    OutputStream stream; ///
    string text;         /// without its terminator
    bool unterminated;   ///
}

/// A task's output: bounded memory, then a spill file.
struct OutputSpool
{
    @disable this(this);

    /**
    Params:
        memoryBudget = bytes of line text kept in memory; the tail stays
            within it once the spool spills.
        spillPath = where the transcript continues past the budget; created
            (with its directory) only when needed. Null drops the oldest
            lines instead, counting them in $(LREF droppedLines).
    */
    this(size_t memoryBudget, string spillPath) @safe pure nothrow
    {
        this.memoryBudget = memoryBudget;
        this.spillPath_ = spillPath;
    }

    /// Appends one line.
    void append(OutputStream stream, scope const(char)[] text, bool unterminated = false) @safe
    {
        ++lineCount;
        if (spilled_)
            writeSpilled(stream, text, unterminated);
        memory ~= SpooledLine(stream, text.idup, unterminated);
        memoryBytes += text.length;
        if (memoryBytes <= memoryBudget)
            return;
        if (!spilled_ && spillPath_.length && startSpill())
        {
            foreach (ref line; memory)
                writeSpilled(line.stream, line.text, line.unterminated);
        }
        // Keep the newest lines within the budget (always the last one).
        size_t drop;
        while (memory.length - drop > 1 && memoryBytes > memoryBudget)
            memoryBytes -= memory[drop++].text.length;
        if (!spilled_)
            droppedLines_ += drop;
        memory = memory[drop .. $].dup;
    }

    /// Lines appended so far.
    size_t lines() const @safe pure nothrow @nogc => lineCount;

    /// The in-memory lines: everything when not spilled, else the tail.
    const(SpooledLine)[] tail() const return @safe pure nothrow @nogc => memory;

    /// Whether the transcript continues in the spill file.
    bool spilled() const @safe pure nothrow @nogc => spilled_;

    /// The spill file's path; meaningful once $(LREF spilled).
    string spillPath() const @safe pure nothrow @nogc => spillPath_;

    /// Lines lost because there was no spill file (or it could not be
    /// opened).
    size_t droppedLines() const @safe pure nothrow @nogc => droppedLines_;

    /// Flushes the spill file, so its contents are complete on disk.
    void flush() @trusted
    {
        if (file.isOpen)
            file.flush();
    }

    /// Calls `sink(line)` for every line kept, in order: the spill file's
    /// when spilled, else memory's.
    void replay(Sink)(scope Sink sink)
    {
        if (!spilled_)
        {
            foreach (ref line; memory)
                sink(line);
            return;
        }
        flush();
        foreach (raw; File(spillPath_, "r").byLine)
        {
            if (raw.length < 2)
                continue;
            const tag = raw[0];
            auto line = SpooledLine(tag == 'e' || tag == 'E' ? OutputStream.stderr : OutputStream.stdout,
                unescape(raw[2 .. $]), tag == 'O' || tag == 'E');
            sink(line);
        }
    }

private:
    size_t memoryBudget;
    string spillPath_;
    SpooledLine[] memory;
    size_t memoryBytes;
    size_t lineCount;
    size_t droppedLines_;
    bool spilled_;
    File file;

    bool startSpill() @trusted
    {
        import std.file : mkdirRecurse;
        import std.path : dirName;

        try
        {
            mkdirRecurse(spillPath_.dirName);
            file = File(spillPath_, "w");
        }
        catch (Exception)
            return false;
        spilled_ = true;
        return true;
    }

    void writeSpilled(OutputStream stream, scope const(char)[] text, bool unterminated) @trusted
    {
        char tag = stream == OutputStream.stderr ? 'e' : 'o';
        if (unterminated)
            tag -= 'a' - 'A';
        char[2] head = [tag, ' '];
        file.rawWrite(head[]);
        // Escaped, so one record stays one line: `\` → `\\`, LF → `\n`,
        // CR → `\r`.
        size_t from;
        foreach (i, c; text)
        {
            const escape = c == '\\' ? `\\` : c == '\n' ? `\n` : c == '\r' ? `\r` : null;
            if (escape is null)
                continue;
            file.rawWrite(text[from .. i]);
            file.rawWrite(escape);
            from = i + 1;
        }
        file.rawWrite(text[from .. $]);
        file.rawWrite("\n");
    }

    // The inverse of `writeSpilled`'s escaping.
    static string unescape(scope const(char)[] text) @safe pure nothrow
    {
        auto result = new char[](0);
        result.reserve(text.length);
        for (size_t i; i < text.length; ++i)
        {
            if (text[i] != '\\' || i + 1 == text.length)
            {
                result ~= text[i];
                continue;
            }
            const next = text[++i];
            result ~= next == 'n' ? '\n' : next == 'r' ? '\r' : next;
        }
        return (() @trusted => cast(string) result)();
    }
}

@("build_primitives.task.output.OutputSpool.keepsEverythingWithinBudget")
@safe
unittest
{
    auto spool = OutputSpool(100, null);
    spool.append(OutputStream.stdout, "one");
    spool.append(OutputStream.stderr, "two", unterminated: true);
    assert(!spool.spilled && spool.lines == 2 && spool.droppedLines == 0);
    string[] seen;
    spool.replay((const ref SpooledLine l) { seen ~= l.text; });
    assert(seen == ["one", "two"]);
    assert(spool.tail[1].stream == OutputStream.stderr && spool.tail[1].unterminated);
}

@("build_primitives.task.output.OutputSpool.withoutSpillDropsTheOldest")
@safe
unittest
{
    auto spool = OutputSpool(8, null);
    foreach (line; ["aaaa", "bbbb", "cccc"])
        spool.append(OutputStream.stdout, line);
    assert(spool.droppedLines == 1);
    assert(spool.tail.length == 2 && spool.tail[0].text == "bbbb");
}

@("build_primitives.task.output.OutputSpool.spillsLosslesslyAndKeepsATail")
@system
unittest
{
    import std.file : exists, readText;
    import std.path : buildPath;
    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmp = TmpFS.create();
    const path = tmp.dir.buildPath("test", "sparkles.base", "output.log");
    auto spool = OutputSpool(10, path);
    spool.append(OutputStream.stdout, "first");
    spool.append(OutputStream.stderr, "second");
    assert(spool.spilled, "11 bytes exceed the budget");
    spool.append(OutputStream.stdout, "third");
    spool.append(OutputStream.stdout, "tail", unterminated: true);
    assert(spool.droppedLines == 0);
    assert(spool.tail.length >= 1 && spool.tail[$ - 1].text == "tail");

    SpooledLine[] all;
    spool.replay((const ref SpooledLine l) { all ~= SpooledLine(l.stream, l.text, l.unterminated); });
    assert(all == [SpooledLine(OutputStream.stdout, "first"), SpooledLine(OutputStream.stderr, "second"),
        SpooledLine(OutputStream.stdout, "third"), SpooledLine(OutputStream.stdout, "tail", true)]);
    spool.flush();
    assert(readText(path) == "o first\ne second\no third\nO tail\n");
}

@("build_primitives.task.output.OutputSpool.spillEscapesLineBreaks")
@system
unittest
{
    import std.file : readText;
    import std.path : buildPath;
    import sparkles.test_utils.tmpfs : TmpFS;

    // A line with an embedded CR, LF, or backslash must replay as itself,
    // not as several lines.
    auto tmp = TmpFS.create();
    const path = tmp.dir.buildPath("output.log");
    auto spool = OutputSpool(1, path);
    const tricky = ["progress\r50%", "two\nlines", `C:\path\n`, "", `\`];
    foreach (line; tricky)
        spool.append(OutputStream.stdout, line);
    assert(spool.spilled);

    string[] back;
    spool.replay((const ref SpooledLine l) { back ~= l.text; });
    assert(back == tricky);
    assert(readText(path) == "o progress\\r50%\no two\\nlines\no C:\\\\path\\\\n\no \no \\\\\n");
}
