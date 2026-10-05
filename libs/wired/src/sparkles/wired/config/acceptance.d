/** Public scalar configuration acceptance scenarios. */
module sparkles.wired.config.acceptance;

import sparkles.wired.config.core : ConfigBuilder, ConfigErrorKind, ConfigInput,
    ConfigSnapshot, ConfigSourceKind, OptionStatus, OptionView, SourceId, visitOption;

/// Equal-priority scalar intent conflicts instead of choosing a loading order.
@("wired.config.scalar.equalPriorityConflict")
@safe unittest
{
    struct Settings { int width = 4; }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto user = builder.registerSource(SourceId("u"),
        ConfigSourceKind.userFile, "user.json", 1000);
    auto project = builder.registerSource(SourceId("p"),
        ConfigSourceKind.projectFile, "project.json", 1000);
    assert(user.hasValue && project.hasValue);
    ConfigInput!Settings u;
    u.width.supplied = true;
    u.width.value = 8;
    ConfigInput!Settings p;
    p.width.supplied = true;
    p.width.value = 16;
    assert(builder.submitBorrowed(user.value, u).kind == ConfigErrorKind.none);
    assert(builder.submitBorrowed(project.value, p).kind == ConfigErrorKind.none);
    auto result = builder.resolve();
    assert(result.hasValue);
    auto snapshot = result.takeValue();
    bool observed;
    auto inspected = snapshot.visitOption!((scope ref const OptionView!int view) {
        observed = true;
        assert(view.status == OptionStatus.conflict);
        assert(view.selectedPriority == 1000);
        assert(view.definitions.length == 3);
        assert(view.contributors.length == 2);
        assert(!view.effective.hasValue);
    })("width");
    assert(inspected.kind == ConfigErrorKind.none && observed);
    auto copy = snapshot.copyConfig();
    assert(copy.hasError && copy.error.kind == ConfigErrorKind.notFullyResolved);
}

/// Typed admission preserves integer widths and floating representations.
@("wired.config.scalar.numericRepresentation")
@safe unittest
{
    import std.typecons : Nullable;
    struct Settings
    {
        byte signedByte;
        ubyte unsignedByte;
        short signedShort;
        ushort unsignedShort;
        int signedInt;
        uint unsignedInt;
        long signedLong;
        ulong unsignedLong;
        float single;
        double precise;
        Nullable!double maybe;
    }
    static float singleFromBits(uint bits) @safe pure nothrow @nogc
    {
        return () @trusted {
            union Bits { uint raw; float value; }
            Bits b;
            b.raw = bits;
            return b.value;
        }();
    }
    static double doubleFromBits(ulong bits) @safe pure nothrow @nogc
    {
        return () @trusted {
            union Bits { ulong raw; double value; }
            Bits b;
            b.raw = bits;
            return b.value;
        }();
    }
    static uint singleBits(float value) @safe pure nothrow @nogc
    {
        return () @trusted {
            union Bits { uint raw; float value; }
            Bits b;
            b.value = value;
            return b.raw;
        }();
    }
    static ulong doubleBits(double value) @safe pure nothrow @nogc
    {
        return () @trusted {
            union Bits { ulong raw; double value; }
            Bits b;
            b.value = value;
            return b.raw;
        }();
    }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto source = builder.registerSource(SourceId("typed"),
        ConfigSourceKind.custom, "typed input");
    assert(source.hasValue);
    ConfigInput!Settings input;
    input.signedByte.supplied = input.unsignedByte.supplied = true;
    input.signedShort.supplied = input.unsignedShort.supplied = true;
    input.signedInt.supplied = input.unsignedInt.supplied = true;
    input.signedLong.supplied = input.unsignedLong.supplied = true;
    input.single.supplied = input.precise.supplied = input.maybe.supplied = true;
    input.signedByte.value = byte.min;
    input.unsignedByte.value = ubyte.max;
    input.signedShort.value = short.min;
    input.unsignedShort.value = ushort.max;
    input.signedInt.value = int.min;
    input.unsignedInt.value = uint.max;
    input.signedLong.value = long.min;
    input.unsignedLong.value = ulong.max;
    input.single.value = singleFromBits(0x7FC00123);
    input.precise.value = doubleFromBits(0x8000000000000000);
    input.maybe.value = Nullable!double(doubleFromBits(0x7FF8000000000456));
    assert(builder.submitBorrowed(source.value, input).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue);
    auto value = copied.takeValue();
    assert(value.signedByte == byte.min && value.unsignedByte == ubyte.max);
    assert(value.signedShort == short.min && value.unsignedShort == ushort.max);
    assert(value.signedInt == int.min && value.unsignedInt == uint.max);
    assert(value.signedLong == long.min && value.unsignedLong == ulong.max);
    assert(singleBits(value.single) == 0x7FC00123);
    assert(doubleBits(value.precise) == 0x8000000000000000);
    assert(!value.maybe.isNull && doubleBits(value.maybe.get) == 0x7FF8000000000456);
}

/// Invalid enum intent rejects before priority selection even when it would lose.
@("wired.config.scalar.invalidOverriddenEnum")
@safe unittest
{
    enum Mode : int { enabled = 1 }
    struct Settings { Mode mode; }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto high = builder.registerSource(SourceId("high"),
        ConfigSourceKind.commandLine, "--mode", 500);
    auto low = builder.registerSource(SourceId("low"),
        ConfigSourceKind.userFile, "file", 2000);
    assert(high.hasValue && low.hasValue);
    ConfigInput!Settings input;
    input.mode.supplied = true;
    input.mode.value = Mode.enabled;
    assert(builder.submitBorrowed(high.value, input).kind == ConfigErrorKind.none);
    const before = builder.usage;
    input.mode.value = cast(Mode) 9;
    auto rejected = builder.submitBorrowed(low.value, input);
    assert(rejected.kind == ConfigErrorKind.invalidValue && rejected.path == "mode");
    assert(builder.usage.definitions == before.definitions
        && builder.usage.payloadBytes == before.payloadBytes);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.mode == Mode.enabled);
}

/// Scoped string and nullable-string views cannot escape their visitor call.
@("wired.config.scalar.scopedStringViewEscape")
@safe unittest
{
    import std.typecons : Nullable;
    struct TextSettings { string text; }
    struct NullableSettings { Nullable!string text; }
    static assert(__traits(compiles, (() @safe {
        ConfigSnapshot!TextSettings owner;
        auto visited = owner.visitOption!((scope ref const OptionView!string view) @safe {
            if (view.effective.hasValue)
            {
                auto length = view.effective.get.length;
            }
        })("text");
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!TextSettings owner;
        const(char)[] escaped;
        auto visited = owner.visitOption!((scope ref const OptionView!string view) @safe {
            escaped = view.effective.get;
        })("text");
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!NullableSettings owner;
        const(char)[] escaped;
        auto visited = owner.visitOption!((scope ref const OptionView!(Nullable!string) view) @safe {
            escaped = view.effective.get.get;
        })("text");
    })()));
}
