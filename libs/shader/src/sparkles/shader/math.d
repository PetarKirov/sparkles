/**
GLSL's built-in functions over $(MREF sparkles,shader,types).

Each is one name that means the same thing in both places a shader runs. On
a `float` or a native vector under LDC they are the LLVM intrinsics the
SPIR-V backend lowers to `GLSL.std.450` (and the x86 backend to an
instruction); on a struct vector, or under DMD, the scalar form applied per
component. The compound ones (`mod`, `clamp`, `mix`, `step`, `smoothstep`,
`fract`) are written once, in terms of the primitives, exactly as the GLSL
specification defines them — so a value computed on the CPU is the value
the GPU computes, up to the usual floating-point ulp.
*/
@compute(CompileFor.hostAndDevice)
module sparkles.shader.math;

import sparkles.shader.attributes : compute, CompileFor;
import sparkles.shader.types;

version (LDC)
    import ldc.intrinsics : llvm_cos, llvm_fabs, llvm_floor, llvm_pow, llvm_sin,
        llvm_sqrt;
else
    import std.math : fabs, floor, cos, sin, sqrt, pow;

// A `float`, or an LDC-native `__vector` of them: what the intrinsics take.
private enum isNative(T) = __traits(isFloating, T);

private T perComponent(alias f, T)(in T v) @safe pure nothrow @nogc
{
    T r;
    static foreach (i; 0 .. vectorLength!T)
        r.array[i] = f(v.array[i]);
    return r;
}

private T perComponent2(alias f, T)(in T a, in T b) @safe pure nothrow @nogc
{
    T r;
    static foreach (i; 0 .. vectorLength!T)
        r.array[i] = f(a.array[i], b.array[i]);
    return r;
}

/// GLSL `floor`.
T floor(T)(in T v) @safe pure nothrow @nogc
{
    static if (isNative!T)
    {
        version (LDC) return llvm_floor(v);
        else return .floor(v);
    }
    else
        return perComponent!((float s) => floor(s), T)(v);
}

/// GLSL `abs`.
T abs(T)(in T v) @safe pure nothrow @nogc
{
    static if (isNative!T)
    {
        version (LDC) return llvm_fabs(v);
        else return fabs(v);
    }
    else
        return perComponent!((float s) => abs(s), T)(v);
}

// `max`/`min` are a comparison and a select on purpose, not `llvm.maxnum`:
// the intrinsic carries IEEE NaN rules the SPIR-V backend spells as `NMax`,
// which spirv-cross then unrolls into an `isnan` dance per component. GLSL's
// own `max` leaves NaN undefined, and so does this.

/// GLSL `max`.
T max(T)(in T a, in T b) @safe pure nothrow @nogc
{
    static if (is(T == float))
        return a > b ? a : b;
    else
        return perComponent2!((float p, float q) => p > q ? p : q, T)(a, b);
}

/// GLSL `min`.
T min(T)(in T a, in T b) @safe pure nothrow @nogc
{
    static if (is(T == float))
        return a < b ? a : b;
    else
        return perComponent2!((float p, float q) => p < q ? p : q, T)(a, b);
}

/// GLSL `sqrt`.
T sqrt(T)(in T v) @safe pure nothrow @nogc
{
    static if (isNative!T)
    {
        version (LDC) return llvm_sqrt(v);
        else return .sqrt(v);
    }
    else
        return perComponent!((float s) => sqrt(s), T)(v);
}

/// GLSL `sin`.
T sin(T)(in T v) @safe pure nothrow @nogc
{
    static if (isNative!T)
    {
        version (LDC) return llvm_sin(v);
        else return .sin(v);
    }
    else
        return perComponent!((float s) => sin(s), T)(v);
}

/// GLSL `cos`.
T cos(T)(in T v) @safe pure nothrow @nogc
{
    static if (isNative!T)
    {
        version (LDC) return llvm_cos(v);
        else return .cos(v);
    }
    else
        return perComponent!((float s) => cos(s), T)(v);
}

/// GLSL `pow`.
T pow(T)(in T a, in T b) @safe pure nothrow @nogc
{
    static if (isNative!T)
    {
        version (LDC) return llvm_pow(a, b);
        else return .pow(a, b);
    }
    else
        return perComponent2!((float p, float q) => pow(p, q), T)(a, b);
}

/// GLSL `mod`: `a - b * floor(a / b)`.
T mod(T)(in T a, in T b) @safe pure nothrow @nogc => a - b * floor(a / b);

/// GLSL `fract`: `v - floor(v)`.
T fract(T)(in T v) @safe pure nothrow @nogc => v - floor(v);

/// GLSL `clamp`: `min(max(v, lo), hi)`.
T clamp(T)(in T v, in T lo, in T hi) @safe pure nothrow @nogc => min(max(v, lo), hi);

/// GLSL `mix`: `a * (1 - t) + b * t`.
T mix(T)(in T a, in T b, float t) @safe pure nothrow @nogc => a * (1.0f - t) + b * t;

/// GLSL `step`: `0` below `edge`, `1` at or above it.
float step(float edge, float v) @safe pure nothrow @nogc => v < edge ? 0.0f : 1.0f;

/// GLSL `smoothstep`: Hermite interpolation between the edges.
float smoothstep(float e0, float e1, float v) @safe pure nothrow @nogc
{
    const t = clamp((v - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

/// GLSL `dot`.
float dot(V)(in V a, in V b) @safe pure nothrow @nogc
if (isShaderVector!V)
{
    const p = a * b;
    float s = 0;
    static foreach (i; 0 .. vectorLength!V)
        s += p.array[i];
    return s;
}

/// GLSL `length`.
float length(V)(in V v) @safe pure nothrow @nogc
if (isShaderVector!V) => sqrt(dot(v, v));

/// Rec. 601 luma — the weighting every luminance-preserving effect here
/// shares, so they agree with each other about what "bright" is.
float luma(in vec3 c) @safe pure nothrow @nogc => dot(c, v3(0.299f, 0.587f, 0.114f));
