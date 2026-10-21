/**
The vector and matrix types a shader is written against, and how to make
one.

$(B The project's one vector type.) `float2`–`float4` and `int2`–`int4` are
$(REF Vector, sparkles,math,vector)s with the device layout, and
`float2x2`–`float4x4` are $(REF Matrix, sparkles,math,matrix)es of them: the
same types the rest of the project computes with, so a value crosses from a
UI's geometry to a shader's uniform without a conversion. `vec2`–`vec4` and
`mat2`–`mat4` are the same types under their GLSL names.

$(B Constructed like any struct.) `float3(1, 0, 0)`, `float4(0.5f)` for a
broadcast, `float4(rgb, 1)` to extend a `float3`; `v2`/`v3`/`v4` and
`i2`/`i3`/`i4` are the same constructors as functions.

$(B Components by name.) `p.x`, `c.w`, and swizzles, read and written:
`c.xyz`, `c.rgb`, `uv.yx`.

$(B One layout on both sides.) A device vector has the size and alignment the
device gives it: `float2` 8 bytes, `float3` and `float4` 16 (a `float3` is
three components and four bytes of padding). So a value, a struct or an array
that holds vectors means the same bytes on the host as in the device's own
memory layout. That is not GLSL's `std140`, which places a scalar that
follows a `vec3` in the `vec3`'s padding: a uniform block declared `std140`
takes its layout from $(MREF sparkles,shaders,layout). Dense host storage that
never crosses to a shader uses the packed variants (`Vec3Packed`, 12 bytes),
converted with `packed` and `aligned`.
*/
@compute(CompileFor.hostAndDevice)
module sparkles.shaders.types;

import sparkles.math.matrix : Matrix;
import sparkles.math.vector : isVector, Layout, Vector;
import sparkles.shaders.attributes : compute, CompileFor;

/// The vector types under the names HLSL, Slang, MSL and D share.
alias float2 = Vector!(float, 2, Layout.device);
alias float3 = Vector!(float, 3, Layout.device); /// ditto
alias float4 = Vector!(float, 4, Layout.device); /// ditto

/// Vectors of two to four `int`s.
alias int2 = Vector!(int, 2, Layout.device);
alias int3 = Vector!(int, 3, Layout.device); /// ditto
alias int4 = Vector!(int, 4, Layout.device); /// ditto

/// The vector types under their GLSL names.
alias vec2 = float2;
alias vec3 = float3; /// ditto
alias vec4 = float4; /// ditto

/// Matrices of `float`, named as HLSL names them: `floatRxC` has `R` rows
/// and `C` columns.
alias float2x2 = Matrix!(float, 2, 2);
alias float2x3 = Matrix!(float, 2, 3); /// ditto
alias float2x4 = Matrix!(float, 2, 4); /// ditto
alias float3x2 = Matrix!(float, 3, 2); /// ditto
alias float3x3 = Matrix!(float, 3, 3); /// ditto
alias float3x4 = Matrix!(float, 3, 4); /// ditto
alias float4x2 = Matrix!(float, 4, 2); /// ditto
alias float4x3 = Matrix!(float, 4, 3); /// ditto
alias float4x4 = Matrix!(float, 4, 4); /// ditto

/// The square matrices under their GLSL names, and GLSL's `matCxR`, which
/// has `C` columns and `R` rows.
alias mat2 = float2x2;
alias mat3 = float3x3; /// ditto
alias mat4 = float4x4; /// ditto
alias mat2x3 = float3x2; /// ditto
alias mat2x4 = float4x2; /// ditto
alias mat3x2 = float2x3; /// ditto
alias mat3x4 = float4x3; /// ditto
alias mat4x2 = float2x4; /// ditto
alias mat4x3 = float3x4; /// ditto

version (LDC_DCompute)
{
    static import ldc.dcompute;
    import ldc.dcompute : Sampler2D, SamplerState;
    import sparkles.math.vector : fromNative;

    /// Samples the image at normalised `uv`: GLSL's `texture(s, uv)`, through
    /// the shared sampler, or through `sampler`, a `SamplerState` parameter of
    /// the entry point. The vocabulary's vectors in and out; the handles by
    /// value, since one may not live in a function's memory.
    float4 sample(S : Sampler2D)(S s, float2 uv)
        => fromNative!float4(ldc.dcompute.sample(s, uv.nativeVector));

    /// ditto
    float4 sample(S : Sampler2D)(S s, SamplerState sampler, float2 uv)
        => fromNative!float4(ldc.dcompute.sample(s, sampler, uv.nativeVector));
}

/// Constructs a `float2`; with one argument, a broadcast.
float2 v2(float x, float y) @safe pure nothrow @nogc => float2(x, y);
/// ditto
float2 v2(float s) @safe pure nothrow @nogc => float2(s);

/// Constructs a `float3`; with one argument, a broadcast.
float3 v3(float x, float y, float z) @safe pure nothrow @nogc => float3(x, y, z);
/// ditto
float3 v3(float s) @safe pure nothrow @nogc => float3(s);

/// Constructs a `float4`; with one argument, a broadcast; from an rgb triple
/// and an alpha, GLSL's `vec4(rgb, a)`.
float4 v4(float x, float y, float z, float w) @safe pure nothrow @nogc => float4(x, y, z, w);
/// ditto
float4 v4(float s) @safe pure nothrow @nogc => float4(s);
/// ditto
float4 v4(in float3 rgb, float w) @safe pure nothrow @nogc => float4(rgb, w);

/// Constructs an `int2`, an `int3` or an `int4`.
int2 i2(int x, int y) @safe pure nothrow @nogc => int2(x, y);
/// ditto
int3 i3(int x, int y, int z) @safe pure nothrow @nogc => int3(x, y, z);
/// ditto
int4 i4(int x, int y, int z, int w) @safe pure nothrow @nogc => int4(x, y, z, w);

/// Whether every component of `a` equals the one of `b`: GLSL's
/// `all(equal(a, b))`, and what `==` means on these vectors.
bool allEqual(V)(in V a, in V b) @safe pure nothrow @nogc
if (isShaderVector!V || isIntVector!V)
    => a == b;

/// Whether `V` is one of the `float` vector types.
enum bool isShaderVector(V) = is(V == float2) || is(V == float3) || is(V == float4);

/// Whether `V` is one of the `int` vector types.
enum bool isIntVector(V) = is(V == int2) || is(V == int3) || is(V == int4);

/// The component count of a vector type.
enum size_t vectorLength(V) = V.dimension;

/// Packed vectors: the components back to back, for dense host storage.
alias Vec2Packed = Vector!(float, 2);
alias Vec3Packed = Vector!(float, 3); /// ditto
alias Vec4Packed = Vector!(float, 4); /// ditto

/// `v`'s components in a packed vector.
Vector!(float, V.dimension) packed(V)(in V v) @safe pure nothrow @nogc
if (isShaderVector!V)
{
    typeof(return) r;
    static foreach (i; 0 .. V.dimension)
        r[i] = v[i];
    return r;
}

/// `p`'s components in the shader vector of its length.
Vector!(float, N, Layout.device) aligned(size_t N)(in Vector!(float, N) p) @safe pure nothrow @nogc
if (N >= 2 && N <= 4)
{
    typeof(return) r;
    static foreach (i; 0 .. N)
        r[i] = p[i];
    return r;
}
