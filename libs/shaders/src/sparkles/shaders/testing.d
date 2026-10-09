/**
The vocabulary's tests, kept out of the modules they exercise.

In a dcompute build (`LDC_DCompute`) a `@compute` module is subject to
LDC's device rules — no string literals, among others — and a test name is a
string literal. So the modules a shader is written against carry no tests of
their own, and this host-only module carries them instead.
*/
module sparkles.shaders.testing;

import sparkles.shaders.math;
import sparkles.shaders.types;

@("shaders.types.constructAndRead")
@safe pure nothrow @nogc unittest
{
    const p = v2(3, 4);
    assert(p.x == 3 && p.y == 4);
    const c = v3(0.25f, 0.5f, 1);
    assert(c.x == 0.25f && c.y == 0.5f && c.z == 1);
    const q = v4(c, 0.5f);
    assert(q.xyz.array == c.array && q.w == 0.5f);
    assert(v3(2).array == v3(2, 2, 2).array);
    assert(v4(1).array == [1, 1, 1, 1]);
}

@("shaders.types.arithmeticIsComponentWiseAndBroadcasts")
@safe pure nothrow @nogc unittest
{
    const a = v3(1, 2, 3);
    const b = v3(10, 20, 30);
    assert((a + b).array == [11, 22, 33]);
    assert((b - a).array == [9, 18, 27]);
    assert((a * b).array == [10, 40, 90]);
    assert((b / a).array == [10, 10, 10]);
    assert((a * 2.0f).array == [2, 4, 6]);
    assert((2.0f * a).array == [2, 4, 6]);
    assert((a + 1.0f).array == [2, 3, 4]);
    assert((-a).array == [-1, -2, -3]);
    // The ternary a shader leans on selects a whole vector.
    const dim = true ? a * 0.5f : a;
    assert(dim.array == [0.5f, 1, 1.5f]);
}

@("shaders.math.builtinsMatchGlslDefinitions")
@safe pure nothrow @nogc unittest
{
    assert(floor(2.7f) == 2 && floor(-0.5f) == -1);
    assert(floor(v2(1.5f, -1.5f)).array == [1, -2]);
    assert(abs(-3.0f) == 3 && abs(v3(-1, 2, -3)).array == [1, 2, 3]);
    assert(max(1.0f, 2.0f) == 2 && min(1.0f, 2.0f) == 1);
    assert(max(v2(1, 5), v2(3, 2)).array == [3, 5]);
    // mod is the GLSL one — sign follows the divisor, unlike fmod.
    assert(mod(5.5f, 2.0f) == 1.5f);
    assert(mod(-0.5f, 2.0f) == 1.5f);
    assert(mod(v2(3, 4), v2(2, 2)).array == [1, 0]);
    assert(fract(2.25f) == 0.25f);
    assert(clamp(1.5f, 0.0f, 1.0f) == 1 && clamp(-1.0f, 0.0f, 1.0f) == 0);
    assert(clamp(v3(-1, 0.5f, 2), v3(0), v3(1)).array == [0, 0.5f, 1]);
    assert(mix(v2(0, 10), v2(10, 20), 0.5f).array == [5, 15]);
    assert(step(1.0f, 0.5f) == 0 && step(1.0f, 1.0f) == 1);
    assert(smoothstep(0.0f, 1.0f, 0.0f) == 0 && smoothstep(0.0f, 1.0f, 1.0f) == 1);
    assert(smoothstep(0.0f, 1.0f, 0.5f) == 0.5f);
    assert(dot(v3(1, 2, 3), v3(4, 5, 6)) == 32);
    assert(length(v2(3, 4)) == 5);
    assert(sqrt(16.0f) == 4);
    assert(exp(0.0f) == 1);
    assert(exp(1.0f) > 2.71828f && exp(1.0f) < 2.71829f);
    assert(exp(-30.0f) > 0 && exp(-30.0f) < 1e-12f, "a halo fades, it never goes negative");
    assert(exp(v2(0, 0)).array == [1, 1]);
    const float base = 4, half = 0.5f;
    assert(pow(base, half) == 2, "a `const` argument resolves under every compiler");
    assert(luma(v3(1)) > 0.999f && luma(v3(1)) < 1.001f);
    assert(luma(v3(0, 0, 1)) > 0, "blue text must not vanish");
}

@("shaders.types.representationPerCompiler")
@safe pure nothrow @nogc unittest
{
    // `SHV2`: under LDC the power-of-two vectors are the compiler's own; the
    // host's `vec3` is three floats under every compiler, never a 16-byte
    // native vector. (The device side, `__vector(float[3])`, is compiled by
    // every generated-shader build: `crtTube` and the bloom passes use it.)
    version (LDC)
    {
        static assert(is(vec2 == __vector(float[2])));
        static assert(is(vec4 == __vector(float[4])));
    }
    else
    {
        static assert(is(vec2 == Vec!2) && is(vec4 == Vec!4));
    }
    static assert(is(vec3 == Vec!3));
    static assert(vec3.sizeof == 3 * float.sizeof);
}

@("shaders.math.transcendentalsMatchTheirDefinitions")
@safe pure nothrow @nogc unittest
{
    import std.math : PI;

    // `SHV5`: hand-derived values — the identities that pin each function,
    // not the host library's own output read back. One part in a million is
    // far inside single precision at these arguments.
    static bool near(float a, float b) => a - b < 1e-6f && b - a < 1e-6f;

    assert(sin(0.0f) == 0 && near(sin(cast(float) PI / 2), 1) && near(sin(cast(float) PI / 6), 0.5f));
    assert(near(sin(-cast(float) PI / 2), -1), "odd");
    assert(cos(0.0f) == 1 && near(cos(cast(float) PI / 3), 0.5f) && near(cos(cast(float) PI), -1));
    assert(near(cos(-cast(float) PI / 3), 0.5f), "even");
    assert(pow(2.0f, 10.0f) == 1024 && pow(9.0f, 0.5f) == 3 && pow(5.0f, 0.0f) == 1);
    assert(near(pow(8.0f, 1.0f / 3.0f), 2));
    // Per component on every vector type, and the same as the scalar form.
    const angles = v3(0, cast(float) PI / 2, cast(float) PI);
    assert(near(sin(angles).y, 1) && near(cos(angles).z, -1));
    assert(pow(v2(2, 3), v2(3, 2)).array == [8, 9]);
    assert(pow(v4(4), v4(0.5f)).array == [2, 2, 2, 2]);
}
