/**
The error vocabulary of `sparkles:font` (FTA9, FTP14).

Every fallible operation returns a `FontResult!T`: a value, or a `FontError`
naming what went wrong, in which table, and where.
*/
module sparkles.font.errors;

import expected : Expected, err, ok;

import sparkles.base.text.errors : NoGcHook;

@safe pure nothrow @nogc:

/// A four-byte OpenType tag, such as `head` or `cmap`, packed big-endian.
struct Tag
{
    @safe pure nothrow @nogc:

    uint value;

    /// The tag with packed value `value`.
    this(uint value) { this.value = value; }

    /// The tag spelled by four ASCII characters.
    this(scope const(char)[] text)
    in (text.length == 4)
    {
        value = (uint(text[0]) << 24) | (uint(text[1]) << 16) | (uint(text[2]) << 8) | uint(text[3]);
    }

    /// No tag: the error is not inside a table.
    bool isNone() const => value == 0;

    /// The tag's four characters.
    char[4] chars() const
        => [cast(char)(value >> 24), cast(char)(value >> 16), cast(char)(value >> 8), cast(char) value];
}

///
@("errors.Tag.roundTrip")
unittest
{
    enum head = Tag("head");
    static assert(head.value == 0x68656164);
    assert(head.chars == "head");
    assert(Tag.init.isNone && !head.isNone);
}

/// What kind of problem an operation found.
enum FontErrorKind : ubyte
{
    notAFont,
    truncated,
    badOffset,
    badValue,
    unsupportedVersion,
    missingTable,
    limitExceeded,
    cycle,
    indexOutOfRange,
    invalidEncoding,
    invalidRange,
    invalidFeatureRange,
    splitScalar,
    unsupportedUnicodeVersion,
    unsupportedEngine,
    unsupportedCapability,
    arithmeticExhausted,
}

/// The fixed limits of FTB3; a `limitExceeded` error names one.
enum FontLimit : ubyte
{
    none,
    compositeDepth,
    compositeComponents,
    cffSubroutineDepth,
    cffOperations,
    colrLayers,
    tableRecords,
    cmapSubtables,
    /// More `fvar` axes than an instance carries (FTM13).
    variationAxes,
    /**
    A caller-supplied array too short for the result (FTP14, FTM13). It has no
    fixed value: the error's `needed` says how long the array must be.
    */
    callerStorage,
}

/// The value of each limit, indexed by `FontLimit`; 0 for `none` and `callerStorage`.
immutable ulong[FontLimit.max + 1] fontLimitValue = [0, 8, 512, 10, 65_536, 1_024, 4_096, 64, 64, 0];

/// A problem in font data, with its location (FTP14).
struct FontError
{
    @safe pure nothrow @nogc:

    /// Marks `tableOffset` as unknown, when the table itself is unreadable.
    enum ulong noTableOffset = ulong.max;

    FontErrorKind kind;
    /// The table being read, or none.
    Tag tag;
    /// Absolute byte offset in the buffer the face was opened from.
    ulong offset;
    /// Offset from the start of `tag`'s table, when that table is readable.
    ulong tableOffset = noTableOffset;
    /// For `limitExceeded`, the limit that was exceeded.
    FontLimit limit;
    /// For `callerStorage`, the array length the operation needs; otherwise 0.
    ulong needed;

    /// The exceeded limit's value, or 0.
    ulong limitValue() const => fontLimitValue[limit];
}

/// The result of a fallible font operation.
alias FontResult(T) = Expected!(T, FontError, NoGcHook);

/// A successful result.
FontResult!T fontOk(T)(T value) => ok!(FontError, NoGcHook)(value);

/// A failed result.
FontResult!T fontErr(T)(FontError error) => err!(T, NoGcHook)(error);

/// An error at absolute `offset`, outside any table.
FontError bufferError(FontErrorKind kind, ulong offset) => FontError(kind, Tag.init, offset);

/// An error inside the table `tag` that starts at `tableStart`.
FontError tableError(FontErrorKind kind, Tag tag, ulong tableStart, ulong relative)
    => FontError(kind, tag, tableStart + relative, relative);

/// A `limitExceeded` error naming `limit`.
FontError limitError(FontLimit limit, Tag tag, ulong offset)
    => FontError(FontErrorKind.limitExceeded, tag, offset, FontError.noTableOffset, limit);

/**
A `limitExceeded` error naming `callerStorage`: the caller's array is shorter
than the `needed` length. The location is that of the data being read, when
there is one.
*/
FontError callerStorageError(ulong needed, Tag tag = Tag.init, ulong offset = 0,
    ulong tableOffset = FontError.noTableOffset)
    => FontError(FontErrorKind.limitExceeded, tag, offset, tableOffset, FontLimit.callerStorage, needed);

///
@("errors.FontError.locations")
unittest
{
    const e = tableError(FontErrorKind.badValue, Tag("name"), 400, 12);
    assert(e.offset == 412 && e.tableOffset == 12 && e.tag == Tag("name"));
    const l = limitError(FontLimit.tableRecords, Tag.init, 4);
    assert(l.kind == FontErrorKind.limitExceeded && l.limitValue == 4_096);
    const r = fontErr!int(l);
    assert(r.hasError && r.error.limit == FontLimit.tableRecords);
    assert(fontOk(3).value == 3);
}

///
@("errors.callerStorageError.needed")
unittest
{
    const e = callerStorageError(12, Tag("name"), 40, 6);
    assert(e.kind == FontErrorKind.limitExceeded && e.limit == FontLimit.callerStorage);
    assert(e.needed == 12 && e.limitValue == 0 && e.offset == 40 && e.tableOffset == 6);
    assert(limitError(FontLimit.variationAxes, Tag("fvar"), 4).limitValue == 64);
}
