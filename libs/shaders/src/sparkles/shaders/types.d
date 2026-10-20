/**
The vector types a shader is written against, and how to make one.

$(B Compiler vectors where the compiler has them.) Under LDC every size is a
`__vector`, which is what reaches SPIR-V as a real `OpTypeVector` — and what
the interface variables must be, because GLSL links a `vec2` varying by name
and type. DMD only knows 16- and 32-byte vectors, so there `vec2` and `vec3`
are a struct with the same surface. Either way the surface is small and the
same: component-wise `+ - * /` against a vector or a scalar, unary `-`, and
`.array` for the components. Not `==`: on a `__vector` it is a mask per
component, on a struct a `bool`, so two compilers would disagree; compare with
`allEqual`, GLSL's `all(equal(a, b))`.

$(B `v2`/`v3`/`v4` construct, because an alias cannot be called.)
`vec3(a, b, c)` is not D — D constructs a `__vector` from a static array only,
and a device module may not spell an array literal — so the constructors are
free functions: `v3(1, 0, 0)`, `v3(0.5f)` for a broadcast, `v4(rgb, 1)`.

$(B Components read by name through UFCS): `p.x`, `p.y`, `c.xyz`, `c.w`.
A `__vector` has no members, so these are functions, and they work on both
representations.

$(B One layout on both sides.) Every representation of a vector has the size
and alignment the device gives it: `vec2` 8 bytes, `vec3` and `vec4` 16 — a
`vec3` is three components and four bytes of padding, as the device compiler
lays it out in memory. So a value, a struct or an array that holds vectors
means the same bytes on the host as in the device's own memory layout. That
is not GLSL's `std140`, which places a scalar that follows a `vec3` in the
`vec3`'s padding: a uniform block declared `std140` needs its own layout. Dense host storage
that never crosses to a shader uses the packed variants (`Vec3Packed`, 12
bytes), converted with `packed` and `aligned`.
*/
@compute(CompileFor.hostAndDevice)
module sparkles.shaders.types;

import sparkles.shaders.attributes : compute, CompileFor;

version (LDC)
{
    // Power-of-two sizes are native vectors under LDC: they lower to
    // `<N x float>`, which is what the SPIR-V backend wants for an interface
    // variable and what the x86 backend legalises without complaint.
    alias vec2 = __vector(float[2]); ///
    alias vec4 = __vector(float[4]); ///
}
else
{
    alias vec2 = Vec!2; ///
    alias vec4 = Vec!4; ///
}

version (LDC_DCompute)
{
    // On the device a `vec3` must be a native vector too: a struct is an
    // aggregate the SPIR-V backend would have to keep in memory (an `in`
    // parameter becomes a `memcpy` it cannot legalise), and the compiler the
    // pipeline runs carries the odd-width vector fixes below.
    alias vec3 = __vector(float[3]); ///
}
else
{
    // On the host `vec3` is the struct on every compiler, on purpose: a
    // released LDC sizes `__vector(float[3])` at 12 bytes while LLVM
    // allocates 16 (a struct holding one is an ICE), and DMD has no such
    // vector at all. The struct is aligned like the device's vector, so the
    // two still occupy the same 16 bytes.
    alias vec3 = Vec!3; ///
}

/// How a `Vec` is laid out in memory.
enum VecLayout
{
    /// As the device lays the vector out: size and alignment rounded up to a
    /// power of two (`vec3`: 16 bytes). What crosses to a shader.
    aligned,
    /// The components back to back, as `float[N]` (`vec3`: 12 bytes): dense
    /// host storage that never reaches a shader.
    packed,
}

/// The size, and alignment, of an aligned `N`-component vector.
enum size_t alignedVectorSize(size_t N) = N <= 1 ? 4 : N == 2 ? 8 : 16;

/**
The fallback vector for compilers without an `N`-wide `float` vector: the
same surface as a `__vector(float[N])`, so shader code compiles the same.
Aligned by default, so it occupies what the device's vector does.
*/
struct Vec(size_t N, VecLayout layout = VecLayout.aligned)
{
    /// the components, as on a `__vector`
    align(layout == VecLayout.aligned ? alignedVectorSize!N : float.alignof)
    float[N] array = 0;

    /// Component-wise arithmetic against another vector.
    Vec opBinary(string op)(in Vec rhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        Vec r;
        static foreach (i; 0 .. N)
            r.array[i] = mixin("array[i] " ~ op ~ " rhs.array[i]");
        return r;
    }

    /// Component-wise arithmetic against a broadcast scalar.
    Vec opBinary(string op)(float rhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        Vec r;
        static foreach (i; 0 .. N)
            r.array[i] = mixin("array[i] " ~ op ~ " rhs");
        return r;
    }

    /// ditto
    Vec opBinaryRight(string op)(float lhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*" || op == "/")
    {
        Vec r;
        static foreach (i; 0 .. N)
            r.array[i] = mixin("lhs " ~ op ~ " array[i]");
        return r;
    }

    /// Negation.
    Vec opUnary(string op : "-")() const @safe pure nothrow @nogc
    {
        Vec r;
        static foreach (i; 0 .. N)
            r.array[i] = -array[i];
        return r;
    }
}

/// Constructs a `vec2`.
vec2 v2(float x, float y) @safe pure nothrow @nogc
{
    vec2 v;
    v.array[0] = x;
    v.array[1] = y;
    return v;
}

/// ditto — a broadcast.
vec2 v2(float s) @safe pure nothrow @nogc => v2(s, s);

/// Constructs a `vec3`.
vec3 v3(float x, float y, float z) @safe pure nothrow @nogc
{
    vec3 v;
    v.array[0] = x;
    v.array[1] = y;
    v.array[2] = z;
    return v;
}

/// ditto — a broadcast.
vec3 v3(float s) @safe pure nothrow @nogc => v3(s, s, s);

/// Constructs a `vec4`.
vec4 v4(float x, float y, float z, float w) @safe pure nothrow @nogc
{
    vec4 v;
    v.array[0] = x;
    v.array[1] = y;
    v.array[2] = z;
    v.array[3] = w;
    return v;
}

/// ditto — from an rgb triple and an alpha, GLSL's `vec4(rgb, a)`.
vec4 v4(in vec3 rgb, float w) @safe pure nothrow @nogc
    => v4(rgb.array[0], rgb.array[1], rgb.array[2], w);

/// ditto — a broadcast.
vec4 v4(float s) @safe pure nothrow @nogc => v4(s, s, s, s);

/// The first component.
float x(V)(in V v) @safe pure nothrow @nogc
if (isShaderVector!V) => v.array[0];

/// The second component.
float y(V)(in V v) @safe pure nothrow @nogc
if (isShaderVector!V) => v.array[1];

/// The third component.
float z(V)(in V v) @safe pure nothrow @nogc
if (isShaderVector!V && v.array.length >= 3) => v.array[2];

/// The fourth component.
float w(V)(in V v) @safe pure nothrow @nogc
if (isShaderVector!V && v.array.length >= 4) => v.array[3];

/// The first two components.
vec2 xy(V)(in V v) @safe pure nothrow @nogc
if (isShaderVector!V && v.array.length >= 3) => v2(v.array[0], v.array[1]);

/// The first three components — a colour's rgb.
vec3 xyz(in vec4 v) @safe pure nothrow @nogc => v3(v.array[0], v.array[1], v.array[2]);

/// ditto
alias rgb = xyz;

/// Whether every component of `a` equals the one of `b`: GLSL's
/// `all(equal(a, b))`, and what `==` means on GLSL vectors. The same `bool`
/// under every compiler, where `==` on a `__vector` is a mask.
bool allEqual(V)(in V a, in V b) @safe pure nothrow @nogc
if (isShaderVector!V || isIntVector!V)
{
    bool same = true;
    static foreach (i; 0 .. vectorLength!V)
        same = same & (a.array[i] == b.array[i]);
    return same;
}

/// Whether `V` is one of the shader vector types.
enum isShaderVector(V) = is(V == vec2) || is(V == vec3) || is(V == vec4);

/// The component count of a shader vector type.
enum vectorLength(V) = V.init.array.length;

/// Packed vectors: the components back to back, for dense host storage.
alias Vec2Packed = Vec!(2, VecLayout.packed);
alias Vec3Packed = Vec!(3, VecLayout.packed); /// ditto
alias Vec4Packed = Vec!(4, VecLayout.packed); /// ditto

/// `v`'s components in a packed vector.
Vec!(vectorLength!V, VecLayout.packed) packed(V)(in V v) @safe pure nothrow @nogc
if (isShaderVector!V)
{
    typeof(return) r;
    r.array = v.array;
    return r;
}

/// `p`'s components in the shader vector of its length.
auto aligned(size_t N)(in Vec!(N, VecLayout.packed) p) @safe pure nothrow @nogc
if (N >= 2 && N <= 4)
{
    static if (N == 2)
        vec2 r;
    else static if (N == 3)
        vec3 r;
    else
        vec4 r;
    r.array = p.array;
    return r;
}

// ---- HLSL-shaped names (`SHV1`) and integer vectors (`SHV9`) -----------------

/// The vector types under the names HLSL, Slang, MSL and D share.
alias float2 = vec2;
alias float3 = vec3; /// ditto
alias float4 = vec4; /// ditto

version (LDC)
{
    alias int2 = __vector(int[2]); /// Vectors of two to four `int`s.
    alias int4 = __vector(int[4]); /// ditto
}
else
{
    alias int2 = IVec!2; ///
    alias int4 = IVec!4; ///
}

version (LDC_DCompute)
    alias int3 = __vector(int[3]); ///
else
    alias int3 = IVec!3; ///

/**
The fallback integer vector for compilers without an `N`-wide `int` vector:
`+`, `-` and `*` against a vector or a broadcast `int`, unary `-`, and
`.array`. Not `/`, which on integers is outside the vocabulary. Aligned as
the device's vector: 8 bytes for two components, 16 for three and four.
*/
struct IVec(size_t N)
{
    /// the components, as on a `__vector`
    align(alignedVectorSize!N) int[N] array = 0;

    /// Component-wise arithmetic against another vector.
    IVec opBinary(string op)(in IVec rhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*")
    {
        IVec r;
        static foreach (i; 0 .. N)
            r.array[i] = mixin("array[i] " ~ op ~ " rhs.array[i]");
        return r;
    }

    /// Component-wise arithmetic against a broadcast scalar.
    IVec opBinary(string op)(int rhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*")
    {
        IVec r;
        static foreach (i; 0 .. N)
            r.array[i] = mixin("array[i] " ~ op ~ " rhs");
        return r;
    }

    /// ditto
    IVec opBinaryRight(string op)(int lhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-" || op == "*")
    {
        IVec r;
        static foreach (i; 0 .. N)
            r.array[i] = mixin("lhs " ~ op ~ " array[i]");
        return r;
    }

    /// Negation.
    IVec opUnary(string op : "-")() const @safe pure nothrow @nogc
    {
        IVec r;
        static foreach (i; 0 .. N)
            r.array[i] = -array[i];
        return r;
    }
}

/// Constructs an `int2`, an `int3` or an `int4`.
int2 i2(int x, int y) @safe pure nothrow @nogc
{
    int2 v;
    v.array[0] = x;
    v.array[1] = y;
    return v;
}

/// ditto
int3 i3(int x, int y, int z) @safe pure nothrow @nogc
{
    int3 v;
    v.array[0] = x;
    v.array[1] = y;
    v.array[2] = z;
    return v;
}

/// ditto
int4 i4(int x, int y, int z, int w) @safe pure nothrow @nogc
{
    int4 v;
    v.array[0] = x;
    v.array[1] = y;
    v.array[2] = z;
    v.array[3] = w;
    return v;
}

/// Whether `V` is one of the integer vector types.
enum isIntVector(V) = is(V == int2) || is(V == int3) || is(V == int4);
