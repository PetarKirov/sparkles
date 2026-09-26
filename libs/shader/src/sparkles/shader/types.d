/**
The vector types a shader is written against, and how to make one.

$(B Compiler vectors where the compiler has them.) Under LDC every size is a
`__vector`, which is what reaches SPIR-V as a real `OpTypeVector` — and what
the interface variables must be, because GLSL links a `vec2` varying by name
and type. DMD only knows 16- and 32-byte vectors, so there `vec2` and `vec3`
are a struct with the same surface. Either way the surface is small and the
same: component-wise `+ - * /` against a vector or a scalar, unary `-`,
`.array` for the components, and equality.

$(B `v2`/`v3`/`v4` construct, because an alias cannot be called.)
`vec3(a, b, c)` is not D — D constructs a `__vector` from a static array only,
and a device module may not spell an array literal — so the constructors are
free functions: `v3(1, 0, 0)`, `v3(0.5f)` for a broadcast, `v4(rgb, 1)`.

$(B Components read by name through UFCS): `p.x`, `p.y`, `c.xyz`, `c.w`.
A `__vector` has no members, so these are functions, and they work on both
representations.
*/
@compute(CompileFor.hostAndDevice)
module sparkles.shader.types;

import sparkles.shader.attributes : compute, CompileFor;

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
    // On the host `vec3` is the struct on every compiler, on purpose. LDC
    // accepts `__vector(float[3])`, but its frontend sizes it at 12 bytes
    // while LLVM allocates 16, so a struct holding one is an ICE ("struct IR
    // size does not match the frontend size") and a bare one asks for a
    // non-power-of-two alignment that LLVM only tolerates with assertions
    // off. The fix is in the compiler (`sparkles/vulkan-shaders`); until a
    // release carries it, three floats it is — and nothing crosses the
    // shader interface as a `vec3`, so the two sides still agree.
    alias vec3 = Vec!3; ///
}

/**
The fallback vector for compilers without an `N`-wide `float` vector: the
same surface as a `__vector(float[N])`, so shader code compiles the same.
*/
struct Vec(size_t N)
{
    float[N] array = 0; /// the components, as on a `__vector`

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

/// Whether `V` is one of the shader vector types.
enum isShaderVector(V) = is(V == vec2) || is(V == vec3) || is(V == vec4);

/// The component count of a shader vector type.
enum vectorLength(V) = V.init.array.length;
