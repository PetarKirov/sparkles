/**
The default uniform block of an entry point, as a D struct (`SHR3`).

Under `vulkan1.3` the `@uniform` parameters of an entry point are the fields
of one uniform block, `<entry>Uniforms`, laid out by `std140`. The host fills
it from the entry point's own signature: `UniformsOf!entry` is a struct with
those fields, named and typed as the parameters are and in their order, so
`writeLayout!(UniformsOf!entry, Rule.std140)` writes the block without a
hand-written mirror that could drift from the shader.
*/
module sparkles.shaders.resources;

import std.traits : fullyQualifiedName, Unqual;

import sparkles.shaders.attributes : binding, PushConstants, resources, Sampler2D, UniformBlock, uniform;

/**
A struct whose fields are the `@uniform` parameters of `entry`, in parameter
order, with the fields of `@resources` parameters flattened in their place
(`SHR2`). Its identifier is `<entry>UniformsBlock`, the name the compiler
gives the block's type (`SHR8`).
*/
template UniformsOf(alias entry)
{
    mixin("struct " ~ __traits(identifier, entry) ~ "UniformsBlock\n{\n"
        ~ uniformFields!entry ~ "}\n"
        ~ "alias UniformsOf = " ~ __traits(identifier, entry) ~ "UniformsBlock;");
}

///
@("resources.UniformsOf.collectsUniformsInOrder")
@safe pure nothrow @nogc
unittest
{
    import sparkles.shaders.attributes : input;
    import sparkles.shaders.layout : layoutOf, Rule;
    import sparkles.shaders.types : vec2, vec3, vec4;

    @resources static struct Tone
    {
        @uniform float gamma;
        @uniform vec3 tint;
    }

    static vec4 grade(@input vec2 uv, @uniform float exposure, Tone tone, @uniform int mode)
        => vec4.init;

    alias U = UniformsOf!grade;
    static assert(__traits(identifier, U) == "gradeUniformsBlock");
    static assert([__traits(allMembers, U)] == ["exposure", "gamma", "tint", "mode"]);
    static assert(is(typeof(U.tint) == vec3) && is(typeof(U.mode) == int));

    enum b = layoutOf!(U, Rule.std140);
    static assert(b["tint"].offset == 16 && b["mode"].offset == 28 && b.size == 32);
}

/**
The type of `entry`'s push-constant block — the `T` of its
`PushConstants!T` parameter, a field of a `@resources` parameter counting as
a parameter — or `void` if it declares none (`SHR4`). A host sizes the
pipeline's push-constant range from it, `layoutOf!(T, Rule.std430).size`, and
names the stages whose entry points declare one.
*/
template PushConstantsOf(alias entry)
{
    static if (is(typeof(entry) P == __parameters))
        alias PushConstantsOf = FirstPushConstants!P;
    else
        static assert(0, __traits(identifier, entry) ~ " is not a function");
}

///
@("resources.PushConstantsOf.findsTheBlockOrVoid")
@safe pure nothrow @nogc
unittest
{
    import sparkles.shaders.attributes : input, PushConstants;
    import sparkles.shaders.layout : layoutOf, Rule;
    import sparkles.shaders.types : vec2, vec4;

    static struct View
    {
        float aspect;
        vec2 offset;
    }

    @resources static struct Frame
    {
        PushConstants!View view;
    }

    static vec4 direct(@input vec2 uv, PushConstants!View view) => vec4.init;
    static vec4 grouped(@input vec2 uv, Frame frame) => vec4.init;
    static vec4 none(@input vec2 uv) => vec4.init;

    static assert(is(PushConstantsOf!direct == View));
    static assert(is(PushConstantsOf!grouped == View));
    static assert(is(PushConstantsOf!none == void));
    static assert(layoutOf!(PushConstantsOf!direct, Rule.std430).size == 16);
}

/// One binding of descriptor set 0 under `vulkan1.3` (`SHR7`), and what it
/// holds.
struct DescriptorBinding
{
    /// The binding number.
    int binding;
    /// What is at it: `sampler`, `image`, `uniformBlock` or `defaultBlock`.
    string kind;
    /// The resource's type, by its fully qualified name: a block's `T`, a
    /// default block's members, `Sampler2D`; empty for the shared sampler.
    string type;
}

/**
The bindings of descriptor set 0 that `entry` uses under `vulkan1.3`, by the
rules the compiler numbers them by (`SHR7`): the shared sampler at 0 when the
entry point takes an image; a `@binding(b)` resource at `b`; and the uniform
blocks, the images and the default uniform block (at the place of the first
`@uniform`) at the next free bindings from 1, in parameter order after
flattening. A push-constant block has none. In binding order.
*/
enum DescriptorBinding[] descriptorBindingsOf(alias entry) = () {
    DescriptorBinding[] bound;
    bool[int] taken;
    foreach (r; resourceListOf!entry)
        if (r.fixed >= 0)
            taken[r.fixed] = true;
    int next = 1;
    int nextFree()
    {
        while (next in taken)
            next++;
        taken[next] = true;
        return next++;
    }
    string defaultType;
    int defaultAt = -1;
    bool images;
    foreach (r; resourceListOf!entry)
    {
        images |= r.kind == "image";
        if (r.kind == "uniform")
        {
            if (defaultAt < 0)
                defaultAt = nextFree();
            defaultType ~= (defaultType.length ? ", " : "") ~ r.type;
        }
        else
            bound ~= DescriptorBinding(r.fixed >= 0 ? r.fixed : nextFree(), r.kind, r.type);
    }
    if (images)
        bound ~= DescriptorBinding(0, "sampler", "");
    if (defaultAt >= 0)
        bound ~= DescriptorBinding(defaultAt, "defaultBlock", defaultType);
    // In binding order: a short insertion sort, CTFE-friendly.
    foreach (i; 1 .. bound.length)
        for (size_t j = i; j > 0 && bound[j - 1].binding > bound[j].binding; j--)
        {
            const t = bound[j - 1];
            bound[j - 1] = bound[j];
            bound[j] = t;
        }
    return bound;
}();

///
@("resources.descriptorBindingsOf.numbersBySHR7")
@safe pure nothrow @nogc
unittest
{
    import sparkles.shaders.attributes : binding, input, Sampler2D, UniformBlock;
    import sparkles.shaders.types : vec2, vec4;

    static struct Light
    {
        float gain;
    }

    @resources static struct Material
    {
        @binding(5) UniformBlock!Light fog;
        Sampler2D albedo;
    }

    static vec4 shade(@input vec2 uv, UniformBlock!Light light, @uniform float exposure,
        Material m, @uniform int mode) => vec4.init;

    enum b = descriptorBindingsOf!shade;
    static assert(b.length == 5);
    static assert(b[0] == DescriptorBinding(0, "sampler", ""));
    static assert(b[1] == DescriptorBinding(1, "uniformBlock", fullyQualifiedName!Light));
    static assert(b[2] == DescriptorBinding(2, "defaultBlock", "float exposure, int mode"));
    static assert(b[3] == DescriptorBinding(3, "image", "Sampler2D"));
    static assert(b[4] == DescriptorBinding(5, "uniformBlock", fullyQualifiedName!Light));
}

private:

// A resource of an entry point after flattening: its kind (`uniform`,
// `image`, `uniformBlock`), its type as D spells it (a uniform's with its
// name) and its fixed binding, or -1.
struct Resource
{
    string kind;
    string type;
    int fixed = -1;
}

template resourceListOf(alias entry)
{
    static if (is(typeof(entry) P == __parameters))
        enum Resource[] resourceListOf = () {
            Resource[] r;
            static foreach (i; 0 .. P.length)
                r ~= resourcesIn!(P[i], __traits(getAttributes, P[i .. i + 1]))(
                    __traits(identifier, P[i .. i + 1]));
            return r;
        }();
    else
        static assert(0, __traits(identifier, entry) ~ " is not a function");
}

// An `in` or `const` parameter is its type, as the compiler takes it; a type
// is named by its full name, so two structs of one name are two types.
Resource[] resourcesIn(Q, attrs...)(string name)
{
    alias T = Unqual!Q;
    int fixed = -1;
    static foreach (a; attrs)
        static if (is(typeof(a) == binding))
            fixed = a.index;
    static if (isMarked!(uniform, attrs))
        return [Resource("uniform", fullyQualifiedName!T ~ " " ~ name, fixed)];
    else static if (is(T == UniformBlock!B, B))
        return [Resource("uniformBlock", fullyQualifiedName!B, fixed)];
    else static if (is(T == Sampler2D))
        return [Resource("image", "Sampler2D", fixed)];
    else static if (is(T == struct) && isMarked!(resources, __traits(getAttributes, T)))
    {
        Resource[] r;
        static foreach (i; 0 .. T.tupleof.length)
            r ~= resourcesIn!(typeof(T.tupleof[i]), __traits(getAttributes, T.tupleof[i]))(
                __traits(identifier, T.tupleof[i]));
        return r;
    }
    else
        return null;
}

template FirstPushConstants(Ts...)
{
    static if (Ts.length == 0)
        alias FirstPushConstants = void;
    else static if (is(Unqual!(Ts[0]) == PushConstants!B, B))
        alias FirstPushConstants = B;
    else static if (is(Unqual!(Ts[0]) == struct) && isMarked!(resources, __traits(getAttributes, Unqual!(Ts[0])))
        && !is(FirstPushConstants!(typeof(Unqual!(Ts[0]).tupleof)) == void))
        alias FirstPushConstants = FirstPushConstants!(typeof(Unqual!(Ts[0]).tupleof));
    else
        alias FirstPushConstants = FirstPushConstants!(Ts[1 .. $]);
}

/// The field declarations of `UniformsOf!entry`, as D source that names
/// each type through `entry`'s own parameter list.
template uniformFields(alias entry)
{
    static if (is(typeof(entry) P == __parameters))
        enum string uniformFields = () {
            string r;
            static foreach (i; 0 .. P.length)
                r ~= fieldsOf!(P[i], __traits(getAttributes, P[i .. i + 1]))(
                    "Parameters!entry[" ~ i.stringof ~ "]",
                    __traits(identifier, P[i .. i + 1]));
            return r;
        }();
    else
        static assert(0, __traits(identifier, entry) ~ " is not a function");
}

/// The field declarations a parameter or field of type `T` with the
/// attributes `attrs` contributes: one for a `@uniform`, its own fields'
/// for an interface struct, none otherwise. `type` spells `T` in D source.
string fieldsOf(Q, attrs...)(string type, string name)
{
    alias T = Unqual!Q;
    static if (isMarked!(uniform, attrs))
        return "    Unqual!(" ~ type ~ ") " ~ name ~ ";\n";
    else static if (is(T == struct) && isMarked!(resources, __traits(getAttributes, T)))
    {
        string r;
        static foreach (i; 0 .. T.tupleof.length)
            r ~= fieldsOf!(typeof(T.tupleof[i]), __traits(getAttributes, T.tupleof[i]))(
                "typeof(" ~ type ~ ".tupleof[" ~ i.stringof ~ "])",
                __traits(identifier, T.tupleof[i]));
        return r;
    }
    else
        return "";
}

enum bool isMarked(alias marker, attrs...) = () {
    bool r;
    static foreach (a; attrs)
        static if (is(typeof(a) == typeof(marker)))
            r = true;
    return r;
}();

template Parameters(alias f)
{
    static if (is(typeof(f) P == __parameters))
        alias Parameters = P;
}
