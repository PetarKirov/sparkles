/**
SDL semantic scalar and source-location vocabulary.

The aggregate arenas and borrowed node ranges land with the parser milestone;
these value types are independent and already form the scalar cells consumed by
the canonical writer.
*/
module sparkles.wired.sdl.document;

import core.time : Duration;
import std.datetime.date : Date;

/// Exact semantic kind retained for every SDL scalar.
enum SdlScalarKind : ubyte
{
    none,
    null_,
    boolean,
    string_,
    character,
    integer,
    longInteger,
    float_,
    double_,
    decimal,
    binary,
    date,
    dateTime,
    zonedDateTime,
    duration,
}

/// A namespace plus local name. An empty namespace is an ordinary SDL name.
struct SdlQualifiedName
{
    string namespace_;
    string localName;
}

/// One source position: zero-based byte offset and one-based display position.
struct SdlPosition
{
    size_t byteOffset;
    uint line = 1;
    uint column = 1;
}

/// Half-open source range.
struct SdlSpan
{
    SdlPosition start;
    SdlPosition end;
}

/** A local civil date-time with exact hectonanosecond fractional precision.

`fractionHnsecs` is the nonnegative fraction after `second` and must be below
10,000,000. The parser additionally constrains date-time literals to their
specified 1-3 decimal digits.
*/
struct SdlDateTime
{
    Date date;
    ubyte hour;
    ubyte minute;
    ubyte second;
    uint fractionHnsecs;
}

/** A local SDL date-time plus its original zone spelling.

Named zones remain valid without a host time-zone database. When resolution is
possible, `utcOffset` carries the exact offset and `hasUtcOffset` distinguishes
it from `Duration.zero` as an unknown offset.
*/
struct SdlZonedDateTime
{
    SdlDateTime local;
    string zone;
    Duration utcOffset;
    bool hasUtcOffset;
}

/** One discriminated SDL scalar.

String and binary payloads are borrowed slices. A parsed document owns their
storage; callers constructing standalone values must keep the backing storage
alive through the write.
*/
struct SdlScalar
{
    private SdlScalarKind _kind = SdlScalarKind.null_;
    private union Payload
    {
        bool booleanValue;
        string stringValue;
        dchar characterValue;
        int integerValue;
        long longValue;
        float floatValue;
        double doubleValue;
        real decimalValue;
        const(ubyte)[] binaryValue;
        Date dateValue;
        SdlDateTime dateTimeValue;
        SdlZonedDateTime zonedDateTimeValue;
        Duration durationValue;
    }
    private Payload _payload;

    /// Constructs SDL `null`.
    this(typeof(null)) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.null_;
    }

    /// Constructs an SDL boolean.
    this(bool value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.boolean;
        _payload.booleanValue = value;
    }

    /// Constructs an SDL string.
    this(string value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.string_;
        _payload.stringValue = value;
    }

    /// Constructs an SDL character.
    this(dchar value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.character;
        _payload.characterValue = value;
    }

    /// Constructs an SDL 32-bit integer.
    this(int value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.integer;
        _payload.integerValue = value;
    }

    /// Constructs an SDL 64-bit integer.
    this(long value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.longInteger;
        _payload.longValue = value;
    }

    /// Constructs an SDL binary32 value.
    this(float value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.float_;
        _payload.floatValue = value;
    }

    /// Constructs an SDL binary64 value.
    this(double value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.double_;
        _payload.doubleValue = value;
    }

    /// Constructs an SDL extended-decimal value.
    static SdlScalar decimal(real value) @safe pure nothrow @nogc
    {
        SdlScalar result;
        result._kind = SdlScalarKind.decimal;
        result._payload.decimalValue = value;
        return result;
    }

    /// Constructs an SDL binary value.
    this(const(ubyte)[] value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.binary;
        _payload.binaryValue = value;
    }

    /// Constructs an SDL date.
    this(Date value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.date;
        _payload.dateValue = value;
    }

    /// Constructs an SDL local date-time.
    this(SdlDateTime value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.dateTime;
        _payload.dateTimeValue = value;
    }

    /// Constructs an SDL zoned date-time.
    this(SdlZonedDateTime value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.zonedDateTime;
        _payload.zonedDateTimeValue = value;
    }

    /// Constructs an SDL duration.
    this(Duration value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.duration;
        _payload.durationValue = value;
    }

    /// The active payload kind.
    SdlScalarKind kind() const @safe pure nothrow @nogc => _kind;

    /// Active boolean payload.
    bool boolean() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.boolean)
    {
        return (() @trusted => _payload.booleanValue)();
    }

    /// Active string payload.
    string stringValue() const @safe pure nothrow @nogc return scope
    in (_kind == SdlScalarKind.string_)
    {
        return (() @trusted => _payload.stringValue)();
    }

    /// Active character payload.
    dchar character() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.character)
    {
        return (() @trusted => _payload.characterValue)();
    }

    /// Active 32-bit integer payload.
    int integer() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.integer)
    {
        return (() @trusted => _payload.integerValue)();
    }

    /// Active 64-bit integer payload.
    long longInteger() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.longInteger)
    {
        return (() @trusted => _payload.longValue)();
    }

    /// Active binary32 payload.
    float floatValue() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.float_)
    {
        return (() @trusted => _payload.floatValue)();
    }

    /// Active binary64 payload.
    double doubleValue() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.double_)
    {
        return (() @trusted => _payload.doubleValue)();
    }

    /// Active extended-decimal payload.
    real decimalValue() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.decimal)
    {
        return (() @trusted => _payload.decimalValue)();
    }

    /// Active binary payload.
    const(ubyte)[] binary() const @safe pure nothrow @nogc return scope
    in (_kind == SdlScalarKind.binary)
    {
        return (() @trusted => _payload.binaryValue)();
    }

    /// Active date payload.
    Date date() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.date)
    {
        return (() @trusted => _payload.dateValue)();
    }

    /// Active local date-time payload.
    SdlDateTime dateTime() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.dateTime)
    {
        return (() @trusted => _payload.dateTimeValue)();
    }

    /// Active zoned date-time payload.
    SdlZonedDateTime zonedDateTime() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.zonedDateTime)
    {
        return (() @trusted => _payload.zonedDateTimeValue)();
    }

    /// Active duration payload.
    Duration duration() const @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.duration)
    {
        return (() @trusted => _payload.durationValue)();
    }
}

@("sdl.document.scalarKindsAndPayloads")
@safe pure nothrow @nogc
unittest
{
    import core.time : seconds;

    assert(SdlScalar(null).kind == SdlScalarKind.null_);
    assert(SdlScalar(true).boolean);
    assert(SdlScalar("text").stringValue == "text");
    assert(SdlScalar(cast(dchar) 'x').character == 'x');
    assert(SdlScalar(int.min).integer == int.min);
    assert(SdlScalar(long.max).longInteger == long.max);
    assert(SdlScalar(1.25f).floatValue == 1.25f);
    assert(SdlScalar(2.5).doubleValue == 2.5);
    assert(SdlScalar.decimal(3.75L).decimalValue == 3.75L);
    static immutable ubyte[3] bytes = [0, 1, 2];
    assert(SdlScalar(bytes[]).binary == bytes[]);
    assert(SdlScalar(5.seconds).duration == 5.seconds);
}

@("sdl.document.sourceVocabulary")
@safe pure nothrow @nogc
unittest
{
    auto name = SdlQualifiedName("x", "platform");
    assert(name.namespace_ == "x" && name.localName == "platform");

    auto span = SdlSpan(SdlPosition(3, 2, 4), SdlPosition(7, 2, 8));
    assert(span.start.byteOffset == 3 && span.end.column == 8);
}
