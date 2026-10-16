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
module sparkles.shaders.math;

import sparkles.shaders.attributes : compute, CompileFor;
import sparkles.shaders.types;

version (LDC)
    import ldc.intrinsics : llvm_cos, llvm_exp, llvm_fabs, llvm_floor, llvm_pow, llvm_sin,
        llvm_sqrt;
else
    import std.math : exp, fabs, floor, cos, sin, sqrt, pow;

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

private T perComponent3(alias f, T)(in T a, in T b, in T c) @safe pure nothrow @nogc
{
    T r;
    static foreach (i; 0 .. vectorLength!T)
        r.array[i] = f(a.array[i], b.array[i], c.array[i]);
    return r;
}

// `s` in every component of a `V`: GLSL's implicit widening of a scalar
// argument, for the forms that take one.
private V splat(V)(float s) @safe pure nothrow @nogc
{
    V r;
    static foreach (i; 0 .. vectorLength!V)
        r.array[i] = s;
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

/// GLSL `exp`: e raised to `v`.
T exp(T)(in T v) @safe pure nothrow @nogc
{
    static if (isNative!T)
    {
        version (LDC) return llvm_exp(v);
        else return cast(T) .exp(cast(float) v);
    }
    else
        return perComponent!((float s) => exp(s), T)(v);
}

/// GLSL `pow`.
T pow(T)(in T a, in T b) @safe pure nothrow @nogc
{
    static if (isNative!T)
    {
        version (LDC) return llvm_pow(a, b);
        else return cast(T) .pow(cast(float) a, cast(float) b); // unqualified: std.math.pow is ambiguous on `const(float)`
    }
    else
        return perComponent2!((float p, float q) => pow(p, q), T)(a, b);
}

/// GLSL `mod`: `a - b * floor(a / b)`.
T mod(T)(in T a, in T b) @safe pure nothrow @nogc => a - b * floor(a / b);

/// GLSL `min`, `max`, `clamp` and `mod` of a vector against a scalar, which
/// GLSL widens to every component.
V min(V)(in V a, float b) @safe pure nothrow @nogc
if (isShaderVector!V) => min(a, splat!V(b));

/// ditto
V max(V)(in V a, float b) @safe pure nothrow @nogc
if (isShaderVector!V) => max(a, splat!V(b));

/// ditto
V clamp(V)(in V v, float lo, float hi) @safe pure nothrow @nogc
if (isShaderVector!V) => clamp(v, splat!V(lo), splat!V(hi));

/// ditto
V mod(V)(in V a, float b) @safe pure nothrow @nogc
if (isShaderVector!V) => mod(a, splat!V(b));

/// GLSL `fract`: `v - floor(v)`.
T fract(T)(in T v) @safe pure nothrow @nogc => v - floor(v);

/// GLSL `clamp`: `min(max(v, lo), hi)`.
T clamp(T)(in T v, in T lo, in T hi) @safe pure nothrow @nogc => min(max(v, lo), hi);

/// GLSL `mix`: `a * (1 - t) + b * t`.
T mix(T)(in T a, in T b, float t) @safe pure nothrow @nogc => a * (1.0f - t) + b * t;

/// ditto — with a weight per component.
V mix(V)(in V a, in V b, in V t) @safe pure nothrow @nogc
if (isShaderVector!V) => a * (splat!V(1.0f) - t) + b * t;

/// GLSL `step`: `0` below `edge`, `1` at or above it.
float step(float edge, float v) @safe pure nothrow @nogc => v < edge ? 0.0f : 1.0f;

/// ditto — per component, against an edge per component or one for all.
V step(V)(in V edge, in V v) @safe pure nothrow @nogc
if (isShaderVector!V) => perComponent2!((float e, float x) => step(e, x), V)(edge, v);

/// ditto
V step(V)(float edge, in V v) @safe pure nothrow @nogc
if (isShaderVector!V) => step(splat!V(edge), v);

/// GLSL `smoothstep`: Hermite interpolation between the edges.
float smoothstep(float e0, float e1, float v) @safe pure nothrow @nogc
{
    const t = clamp((v - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

/// ditto — per component, against edges per component or one pair for all.
V smoothstep(V)(in V e0, in V e1, in V v) @safe pure nothrow @nogc
if (isShaderVector!V)
    => perComponent3!((float a, float b, float x) => smoothstep(a, b, x), V)(e0, e1, v);

/// ditto
V smoothstep(V)(float e0, float e1, in V v) @safe pure nothrow @nogc
if (isShaderVector!V) => smoothstep(splat!V(e0), splat!V(e1), v);

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
