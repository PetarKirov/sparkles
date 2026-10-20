/**
Where each byte of a uniform or push-constant block goes (`SHR6`).

D's struct layout is neither GLSL's `std140` nor its `std430`: a `vec3`
followed by a `float` puts the `float` at 16 in D (a `vec3` occupies 16
bytes, `SHV2`) and at 12 in both GLSL layouts, and a `float[4]` has a stride
of 4 in D and of 16 under `std140`. The host and the device must agree on
every byte, so one function says where each goes: `layoutOf!(T, rule)` gives
the offsets, and `writeLayout!(T, rule)` writes a host value at them. The
compiler lays the block out by the same rules, which the OpenGL 4.6
specification defines in §7.6.2.2.

A block's members are `float`, `int` and `uint` scalars, vectors of two to
four of them, static arrays of block types and structs of block types.
*/
module sparkles.shaders.layout;

import sparkles.shaders.types : isIntVector, isShaderVector, vectorLength;

/// A GLSL block layout.
enum Rule
{
    /// Uniform blocks: arrays and structs align to 16 bytes.
    std140,
    /// Push-constant (and storage) blocks: they align to their members.
    std430,
}

/// Where one field of a block lies.
struct FieldLayout
{
    string name;        /// the D field's name
    size_t offset;      /// from the start of the block
    size_t size;        /// the bytes the field occupies
    size_t arrayStride; /// for an array, the distance between its elements; else 0
}

/// A block's layout: its fields, its size and its alignment.
struct BlockLayout
{
    FieldLayout[] fields; ///
    size_t size;          /// the block's size, rounded up to its alignment
    size_t alignment;     ///

    /// The layout of the field named `name`.
    FieldLayout opIndex(string name) const @safe pure
    {
        foreach (f; fields)
            if (f.name == name)
                return f;
        assert(0, "no field `" ~ name ~ "`");
    }
}

/// The layout of the struct `T` under `rule`.
enum BlockLayout layoutOf(T, Rule rule) = () {
    static assert(is(T == struct) && !isVector!T, "a block is a struct, not `" ~ T.stringof ~ "`");
    BlockLayout b;
    size_t at = 0;
    static foreach (i; 0 .. T.tupleof.length)
    {{
        alias F = typeof(T.tupleof[i]);
        at = roundUp(at, alignmentOf!(F, rule));
        static if (__traits(isStaticArray, F))
            enum stride = strideOf!(typeof(F.init[0]), rule);
        else
            enum stride = 0;
        b.fields ~= FieldLayout(__traits(identifier, T.tupleof[i]), at, sizeOf!(F, rule), stride);
        at += sizeOf!(F, rule);
    }}
    b.alignment = alignmentOf!(T, rule);
    b.size = roundUp(at, b.alignment);
    return b;
}();

///
@("layout.layoutOf.std140AndStd430")
@safe pure nothrow @nogc
unittest
{
    import sparkles.shaders.types : vec2, vec3, vec4;

    static struct Light
    {
        vec3 colour;     // a vec3 aligns to 16 and occupies 12
        float gain;      // so a scalar fits in its last 4 bytes
        vec2 at;
        float[3] weights; // std140: stride 16; std430: stride 4
        vec4 tint;
    }

    // Offsets worked by hand from the OpenGL 4.6 specification, §7.6.2.2.
    enum s140 = layoutOf!(Light, Rule.std140);
    static assert(s140["colour"].offset == 0 && s140["colour"].size == 12);
    static assert(s140["gain"].offset == 12);
    static assert(s140["at"].offset == 16);
    static assert(s140["weights"].offset == 32 && s140["weights"].arrayStride == 16);
    static assert(s140["weights"].size == 48);
    static assert(s140["tint"].offset == 80);
    static assert(s140.size == 96 && s140.alignment == 16);

    enum s430 = layoutOf!(Light, Rule.std430);
    static assert(s430["gain"].offset == 12);
    static assert(s430["at"].offset == 16);
    static assert(s430["weights"].offset == 24 && s430["weights"].arrayStride == 4);
    static assert(s430["tint"].offset == 48);
    static assert(s430.size == 64 && s430.alignment == 16);
}

///
@("layout.layoutOf.nestedStructsAndTrailingScalars")
@safe pure nothrow @nogc
unittest
{
    import sparkles.shaders.types : vec2;

    static struct Inner
    {
        vec2 p;
        float q;
    }

    static struct Outer
    {
        float a;
        Inner inner;  // std140: a struct aligns to 16; std430: to its members (8)
        float b;
        Inner[2] pair;
        float tail;   // a scalar after an array starts on the array's end
    }

    enum s140 = layoutOf!(Outer, Rule.std140);
    static assert(s140["inner"].offset == 16 && s140["inner"].size == 16);
    static assert(s140["b"].offset == 32);
    static assert(s140["pair"].offset == 48 && s140["pair"].arrayStride == 16);
    static assert(s140["tail"].offset == 80);
    static assert(s140.size == 96);

    enum s430 = layoutOf!(Outer, Rule.std430);
    static assert(s430["inner"].offset == 8 && s430["inner"].size == 16);
    static assert(s430["b"].offset == 24);
    static assert(s430["pair"].offset == 32 && s430["pair"].arrayStride == 16);
    static assert(s430["tail"].offset == 64);
    static assert(s430.size == 72 && s430.alignment == 8);
}

///
@("layout.layoutOf.aStructWithAnArrayFieldIsAStruct")
@safe pure nothrow @nogc
unittest
{
    static struct Weights
    {
        float[4] array;
    }

    static struct Block
    {
        Weights weights;
        float tail;
    }

    // `Weights` is a struct holding a `float[4]`, not a vector: std140 gives
    // the array a stride of 16, and the struct is 64 bytes.
    enum b = layoutOf!(Block, Rule.std140);
    static assert(b["weights"].size == 64 && b["tail"].offset == 64 && b.size == 80);
}

/**
Writes `value` into `buffer` at the offsets `layoutOf!(T, rule)` gives, from
`at`. The bytes between fields are left as they are. `buffer` must hold
`layoutOf!(T, rule).size` bytes after `at`.
*/
void writeLayout(T, Rule rule)(in T value, scope ubyte[] buffer, size_t at = 0)
{
    static if (is(T == struct) && !isVector!T)
    {
        enum b = layoutOf!(T, rule);
        assert(buffer.length >= at + b.size, "the buffer is smaller than the block");
        static foreach (i; 0 .. T.tupleof.length)
            writeValue!(typeof(T.tupleof[i]), rule)(value.tupleof[i], buffer, at + b.fields[i].offset);
    }
    else
        static assert(0, "a block is a struct, not `" ~ T.stringof ~ "`");
}

///
@("layout.writeLayout.placesEachFieldAtItsOffset")
@safe pure nothrow @nogc
unittest
{
    import sparkles.shaders.types : v3, vec3;

    static struct Block
    {
        vec3 colour;
        float gain;
        int[2] counts;
    }

    Block b;
    b.colour = v3(1, 2, 3);
    b.gain = 4;
    b.counts = [5, 6];
    ubyte[layoutOf!(Block, Rule.std140).size] bytes;
    writeLayout!(Block, Rule.std140)(b, bytes[]);
    float floatAt(size_t o) => (() @trusted => *cast(const float*) &bytes[o])();
    int intAt(size_t o) => (() @trusted => *cast(const int*) &bytes[o])();
    assert(floatAt(0) == 1 && floatAt(4) == 2 && floatAt(8) == 3);
    assert(floatAt(12) == 4);
    assert(intAt(16) == 5 && intAt(32) == 6); // std140: stride 16
}

private:

size_t roundUp(size_t n, size_t to) @safe pure nothrow @nogc => (n + to - 1) / to * to;

enum bool isScalar(T) = is(T == float) || is(T == int) || is(T == uint);

// The vocabulary's vectors only: a user struct with an `array` field is a
// struct, as the compiler lays it out.
enum bool isVector(T) = isShaderVector!T || isIntVector!T;

/// A type's base alignment (§7.6.2.2, rules 1–10).
template alignmentOf(T, Rule rule)
{
    static if (isScalar!T)
        enum size_t alignmentOf = 4;
    else static if (isVector!T)
        enum size_t alignmentOf = vectorLength!T == 2 ? 8 : 16;
    else static if (__traits(isStaticArray, T))
    {
        // Rule 4: an array aligns as its element, rounded up to a vec4's
        // alignment under std140.
        enum size_t element = alignmentOf!(typeof(T.init[0]), rule);
        enum size_t alignmentOf = rule == Rule.std140 ? roundUp(element, 16) : element;
    }
    else static if (is(T == struct))
    {
        // Rule 9: a struct aligns as its most aligned member, rounded up to a
        // vec4's alignment under std140.
        enum size_t members = () {
            size_t a = 4;
            static foreach (i; 0 .. T.tupleof.length)
                if (alignmentOf!(typeof(T.tupleof[i]), rule) > a)
                    a = alignmentOf!(typeof(T.tupleof[i]), rule);
            return a;
        }();
        enum size_t alignmentOf = rule == Rule.std140 ? roundUp(members, 16) : members;
    }
    else
        static assert(0, "`" ~ T.stringof ~ "` cannot be a member of a block");
}

/// The distance between the elements of an array of `E`.
enum size_t strideOf(E, Rule rule) = roundUp(sizeOf!(E, rule),
    rule == Rule.std140 ? roundUp(alignmentOf!(E, rule), 16) : alignmentOf!(E, rule));

/// The bytes a value of `T` occupies in a block.
template sizeOf(T, Rule rule)
{
    static if (isScalar!T)
        enum size_t sizeOf = 4;
    else static if (isVector!T)
        enum size_t sizeOf = 4 * vectorLength!T;
    else static if (__traits(isStaticArray, T))
        enum size_t sizeOf = strideOf!(typeof(T.init[0]), rule) * T.length;
    else static if (is(T == struct))
        enum size_t sizeOf = layoutOf!(T, rule).size;
    else
        static assert(0, "`" ~ T.stringof ~ "` cannot be a member of a block");
}

void writeValue(T, Rule rule)(in T value, scope ubyte[] buffer, size_t at)
{
    static if (isScalar!T)
    {
        const bytes = (() @trusted => (cast(const(ubyte)*) &value)[0 .. 4])();
        buffer[at .. at + 4] = bytes;
    }
    else static if (isVector!T)
    {
        foreach (i; 0 .. vectorLength!T)
            writeValue!(typeof(T.init.array[0]), rule)(value.array[i], buffer, at + 4 * i);
    }
    else static if (__traits(isStaticArray, T))
    {
        foreach (i, ref e; value)
            writeValue!(typeof(T.init[0]), rule)(e, buffer, at + i * strideOf!(typeof(T.init[0]), rule));
    }
    else static if (is(T == struct))
        writeLayout!(T, rule)(value, buffer, at);
}
