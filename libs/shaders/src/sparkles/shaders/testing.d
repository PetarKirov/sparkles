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

@("shaders.math.vectorFormsArePerComponent")
@safe pure nothrow @nogc unittest
{
    // `SHV5`: GLSL defines these per component, and widens a scalar
    // argument to every component; each form must equal the scalar one
    // applied to each component.
    const v = v3(-1.5f, 0.25f, 3);
    const e = v3(0, 0.5f, 2);
    const float[3] stepped = [step(0, -1.5f), step(0.5f, 0.25f), step(2, 3)];
    assert(step(e, v).array == stepped);
    assert(step(0.0f, v).array == [0, 1, 1]);
    const float[3] smoothed = [smoothstep(-2, 4, -1.5f), smoothstep(-2, 4, 0.25f),
        smoothstep(-2, 4, 3.0f)];
    assert(smoothstep(v3(-2), v3(4), v).array == smoothed);
    assert(smoothstep(0.0f, 1.0f, v2(0.5f, 2)).array == [0.5f, 1]);
    assert(mix(v2(0, 10), v2(10, 20), v2(0.5f, 0.25f)).array == [5, 12.5f]);
    assert(min(v, 0.0f).array == [-1.5f, 0, 0] && max(v, 0.0f).array == [0, 0.25f, 3]);
    assert(clamp(v, 0.0f, 1.0f).array == [0, 0.25f, 1]);
    assert(mod(v2(3, -0.5f), 2.0f).array == [1, 1.5f]);
}

@("shaders.types.allEqualIsOneBool")
@safe pure nothrow @nogc unittest
{
    // `SHV1`: GLSL's vector `==`, the same `bool` under every compiler.
    assert(allEqual(v2(1, 2), v2(1, 2)) && !allEqual(v2(1, 2), v2(1, 3)));
    assert(allEqual(v3(0.5f), v3(0.5f)) && !allEqual(v3(0, 0, 1), v3(0)));
    assert(allEqual(v4(1, 2, 3, 4), v4(1, 2, 3, 4)) && !allEqual(v4(1), v4(1, 1, 1, 2)));
}

@("shaders.attributes.standInsCompileAsPlainD")
@safe pure nothrow @nogc unittest
{
    import sparkles.shaders.attributes : fragment, input, Sampler2D, uniform;

    // `SHV8`: outside a device compilation every attribute and the
    // `Sampler2D` handle exist and do nothing, so a function spelled like an
    // entry point is ordinary D a host calls.
    @fragment static vec4 entry(@input vec2 uv, Sampler2D texture0, @uniform float amount)
        => v4(uv.x * amount);
    assert(entry(v2(2, 0), Sampler2D.init, 0.5f).x == 1);
}

@("shaders.types.oneLayoutOnBothSides")
@safe pure nothrow @nogc unittest
{
    // `SHV2`: every vector occupies what the device's does, under every
    // compiler, so a struct or an array that holds vectors means the same
    // bytes on both sides.
    static assert(vec2.sizeof == 8 && vec2.alignof == 8);
    static assert(vec3.sizeof == 16 && vec3.alignof == 16);
    static assert(vec4.sizeof == 16 && vec4.alignof == 16);

    static struct Light { vec3 colour; float gain; }
    static assert(Light.gain.offsetof == 16 && (vec3[2]).sizeof == 32);

    static assert(Vec3Packed.sizeof == 12 && (Vec3Packed[2]).sizeof == 24);
    assert(v3(1, 2, 3).packed.aligned.array == [1, 2, 3]);
    assert(v2(1, 2).packed.array == [1, 2]);
}

@("shaders.types.intVectorsAddSubtractMultiply")
@safe pure nothrow @nogc unittest
{
    import sparkles.shaders.types : allEqual, float3, i2, i3, i4, int2, int3, int4, vec3;

    static assert(is(float3 == vec3));
    static assert(int2.sizeof == 8 && int4.sizeof == 16 && int4.alignof == 16);
    static assert(int3.sizeof == 16 && int3.alignof == 16);

    assert(allEqual(i2(1, 2) + i2(3, 4), i2(4, 6)));
    assert(allEqual(i3(1, 2, 3) * 2, i3(2, 4, 6)));
    assert(allEqual(10 - i4(1, 2, 3, 4), i4(9, 8, 7, 6)));
    assert(allEqual(-i3(1, -2, 3), i3(-1, 2, -3)));
}

@("shaders.resources.inParametersAreTheirTypes")
@safe pure nothrow @nogc unittest
{
    import sparkles.shaders.attributes : builtin, Builtin, input, PushConstants, uniform,
        UniformBlock;
    import sparkles.shaders.layout : layoutOf, Rule;
    import sparkles.shaders.resources : descriptorBindingsOf, PushConstantsOf, UniformsOf;
    import sparkles.shaders.stages : stagesLink;

    // An `in` parameter is its type for every reflection template, as the
    // compiler takes it.
    static struct View
    {
        float aspect;
    }

    static struct Out
    {
        @builtin(Builtin.position) vec4 position;
        vec4 colour;
    }

    static Out vs(@builtin(Builtin.vertexIndex) in int i, in PushConstants!View view) => Out.init;
    static vec4 fs(@input in vec4 colour, @uniform in float gain, in UniformBlock!View v) => colour;

    static assert(is(PushConstantsOf!vs == View));
    static assert(is(typeof(UniformsOf!fs.gain) == float));
    static assert(layoutOf!(UniformsOf!fs, Rule.std140).size == 16);
    static assert(descriptorBindingsOf!fs.length == 2);
    static assert(stagesLink!(vs, fs));
}

@("shaders.layout.aVectorIsNotABlock")
@safe pure nothrow @nogc unittest
{
    import sparkles.shaders.layout : layoutOf, Rule;

    // On the host `vec3` is a struct; it is still a vector, not a block.
    static assert(!__traits(compiles, layoutOf!(vec3, Rule.std140)));
}
