/**
The vocabulary's tests, kept out of the modules they exercise.

Under `-d-version=SparklesShaderDevice` a `@compute` module is subject to
LDC's device rules — no string literals, among others — and a test name is a
string literal. So the modules a shader is written against carry no tests of
their own, and this host-only module carries them instead.
*/
module sparkles.shader.testing;

import sparkles.shader.math;
import sparkles.shader.types;

@("shader.types.constructAndRead")
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

@("shader.types.arithmeticIsComponentWiseAndBroadcasts")
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

@("shader.math.builtinsMatchGlslDefinitions")
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
    assert(luma(v3(1)) > 0.999f && luma(v3(1)) < 1.001f);
    assert(luma(v3(0, 0, 1)) > 0, "blue text must not vanish");
}
