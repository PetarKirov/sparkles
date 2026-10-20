/**
Whether a vertex and a fragment entry point make one pipeline (`SHF9`).

The two stages are compiled as separate entry points, and a mismatch between
them is caught by no validator: the pipeline links, and the fragment stage
reads what the vertex stage never wrote. D can check it where the pair is
chosen, from the two signatures.
*/
module sparkles.shaders.stages;

import std.traits : Unqual;

import sparkles.shaders.attributes : builtin, input, PushConstants;
import sparkles.shaders.resources : descriptorBindingsOf, PushConstantsOf;

/**
Whether every `@input` of the fragment entry point `F` is an output of the
vertex entry point `V` with the same name, the same type and the same
location; when both declare a push-constant block, whose blocks have the
same type (`SHR4`), since the two share one push-constant range; and where
both use a binding of descriptor set 0 (`descriptorBindingsOf`, `SHR7`),
whose resources there are of the same kind and type.

A vertex entry point returns a struct whose fields, but the one marked
`@builtin`, are its outputs, at locations 0, 1, 2, … in field order; a
fragment entry point's `@input` parameters are its inputs, at locations in
parameter order.
*/
enum bool stagesLink(alias V, alias F) = () {
    alias R = typeof(V(Parameters!V.init));
    static assert(is(R == struct), __traits(identifier, V) ~ " is not a vertex entry point: it returns "
        ~ R.stringof);
    string[] outNames, outTypes;
    static foreach (i, field; R.tupleof)
        static if (!isBuiltin!(__traits(getAttributes, R.tupleof[i])))
        {
            outNames ~= __traits(identifier, R.tupleof[i]);
            outTypes ~= Unqual!(typeof(field)).mangleof;
        }
    size_t location = 0;
    bool links = true;
    static foreach (i; 0 .. Parameters!F.length)
        static if (isInput!(__traits(getAttributes, Parameters!F[i .. i + 1])))
        {
            links = links && location < outNames.length
                && outNames[location] == parameterName!(F, i)
                && outTypes[location] == Unqual!(Parameters!F[i]).mangleof;
            location++;
        }
    foreach (v; descriptorBindingsOf!V)
        foreach (f; descriptorBindingsOf!F)
            if (v.binding == f.binding)
                links = links && v.kind == f.kind && v.type == f.type;
    return links && (is(PushConstantsOf!V == void) || is(PushConstantsOf!F == void)
        || is(PushConstantsOf!V == PushConstantsOf!F));
}();

///
@("stages.stagesLink.matchesNamesTypesAndLocations")
@safe pure nothrow @nogc
unittest
{
    import sparkles.shaders.attributes : binding, Builtin, uniform, UniformBlock;
    import sparkles.shaders.types : vec2, vec4;

    static struct Out
    {
        @builtin(Builtin.position) vec4 position;
        vec4 colour;
        vec2 uv;
    }

    static Out vs(@builtin(Builtin.vertexIndex) int i) => Out.init;
    static vec4 fs(@input vec4 colour, @input vec2 uv) => colour;
    static vec4 swapped(@input vec2 uv, @input vec4 colour) => colour;
    static vec4 renamed(@input vec4 color) => color;
    static vec4 retyped(@input vec2 colour) => vec4.init;
    static vec4 tooMany(@input vec4 colour, @input vec2 uv, @input vec2 extra) => colour;
    static vec4 fewer(@input vec4 colour) => colour;

    static assert(stagesLink!(vs, fs));
    static assert(stagesLink!(vs, fewer));
    static assert(!stagesLink!(vs, swapped));
    static assert(!stagesLink!(vs, renamed));
    static assert(!stagesLink!(vs, retyped));
    static assert(!stagesLink!(vs, tooMany));

    static struct A { float aspect; }
    static struct B { float scale; }
    static Out pushing(@builtin(Builtin.vertexIndex) int i, PushConstants!A pc) => Out.init;
    static vec4 sameBlock(@input vec4 colour, PushConstants!A pc) => colour;
    static vec4 otherBlock(@input vec4 colour, PushConstants!B pc) => colour;
    static assert(stagesLink!(pushing, sameBlock));
    static assert(stagesLink!(pushing, fs)); // one stage without a block
    static assert(!stagesLink!(pushing, otherBlock));

    // A binding both stages use holds one kind and type of resource.
    static Out lit(@builtin(Builtin.vertexIndex) int i, UniformBlock!A a) => Out.init;
    static vec4 sameUniforms(@input vec4 colour, UniformBlock!A a) => colour;
    static vec4 otherUniforms(@input vec4 colour, UniformBlock!B b) => colour;
    static vec4 otherKind(@input vec4 colour, @uniform float a) => colour;
    static vec4 elsewhere(@input vec4 colour, @binding(2) UniformBlock!B b) => colour;
    static assert(stagesLink!(lit, sameUniforms));
    static assert(!stagesLink!(lit, otherUniforms));
    static assert(!stagesLink!(lit, otherKind));
    static assert(stagesLink!(lit, elsewhere));
}

private:

template Parameters(alias f)
{
    static if (is(typeof(f) P == function))
        alias Parameters = P;
    else static if (is(typeof(*f) P == function))
        alias Parameters = P;
    else
        static assert(0, __traits(identifier, f) ~ " is not a function");
}

template parameterName(alias f, size_t i)
{
    static if (is(typeof(f) P == __parameters))
        enum parameterName = __traits(identifier, P[i .. i + 1]);
}

enum bool isBuiltin(attrs...) = () {
    bool r;
    static foreach (a; attrs)
        static if (is(typeof(a) == builtin))
            r = true;
    return r;
}();

enum bool isInput(attrs...) = () {
    bool r;
    static foreach (a; attrs)
        static if (is(typeof(a) == typeof(input)))
            r = true;
    return r;
}();
