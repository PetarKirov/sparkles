/**
Whether a vertex and a fragment entry point make one pipeline (`SHF9`).

The two stages are compiled as separate entry points, and a mismatch between
them is caught by no validator: the pipeline links, and the fragment stage
reads what the vertex stage never wrote. D can check it where the pair is
chosen, from the two signatures.
*/
module sparkles.shaders.stages;

import sparkles.shaders.attributes : builtin, input;

/**
Whether every `@input` of the fragment entry point `F` is an output of the
vertex entry point `V` with the same name, the same type and the same
location.

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
            outTypes ~= typeof(field).stringof;
        }
    size_t location = 0;
    bool links = true;
    static foreach (i; 0 .. Parameters!F.length)
        static if (isInput!(__traits(getAttributes, Parameters!F[i .. i + 1])))
        {
            links = links && location < outNames.length
                && outNames[location] == parameterName!(F, i)
                && outTypes[location] == Parameters!F[i].stringof;
            location++;
        }
    return links;
}();

///
@("stages.stagesLink.matchesNamesTypesAndLocations")
@safe pure nothrow @nogc
unittest
{
    import sparkles.shaders.attributes : Builtin;
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
