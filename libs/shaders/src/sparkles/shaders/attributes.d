/**
The attributes and opaque handles a shader module is written against.

In a dcompute build (`LDC_DCompute`) these are LDC's `ldc.dcompute`
symbols, which the compiler recognises: `@compute` on a module makes it
device code, `@fragment` and `@vertex` on a function make it an entry point
of that stage, `@profiles` names the profiles it is built for, and the
parameter markers (`@input`, `@uniform`, `@builtin`) and `Sampler2D`
describe the interface the compiler synthesises around it. Without the version they are inert stand-ins
with the same names and shapes, so the same source compiles as ordinary D on
any compiler.
*/
module sparkles.shaders.attributes;

import sparkles.shaders.capabilities : Profile;

version (LDC_DCompute)
{
    public import ldc.dcompute : compute, CompileFor, fragment, vertex, input, uniform,
        builtin, Builtin, SamplerState, Sampler2D, sample;
    import ldc.dcompute : _profiles;
}
else
{
    /// Whether a `@compute` module is emitted for the device only, or for
    /// both the host and the device. Stand-in for `ldc.dcompute.CompileFor`.
    enum CompileFor : int
    {
        deviceOnly = 0,    ///
        hostAndDevice = 1, ///
    }

    /// Marks a module as shader code. Stand-in for `ldc.dcompute.compute`.
    struct compute
    {
        CompileFor codeProduction = CompileFor.deviceOnly; ///
    }

    private struct _shader
    {
        int stage;
    }

    /// Marks a function as a fragment-shader entry point. Stand-in for
    /// `ldc.dcompute.fragment`.
    enum fragment = _shader(0);

    /// Marks a function as a vertex-shader entry point. Stand-in for
    /// `ldc.dcompute.vertex`.
    enum vertex = _shader(1);

    /// The built-in variables a stage reads or writes. Stand-in for
    /// `ldc.dcompute.Builtin`.
    enum Builtin : int
    {
        vertexIndex = 0,   /// the vertex's index: an `int` vertex input
        instanceIndex = 1, /// the instance's index: an `int` vertex input
        position = 2,      /// the clip-space position: a `vec4` vertex output
    }

    /// Marks a parameter, or a field of a `@vertex` result, as a built-in
    /// variable. Stand-in for `ldc.dcompute.builtin`.
    struct _builtin
    {
        Builtin variable; ///
    }

    /// ditto
    alias builtin = _builtin;

    // The profiles of an entry point or module. Stand-in for
    // `ldc.dcompute._profiles`.
    struct _profiles
    {
        string names;
    }

    private struct _input
    {
    }

    /// Marks a `@fragment` parameter as an interface input (a varying).
    enum input = _input();

    private struct _uniform
    {
    }

    /// Marks a `@fragment` parameter as a uniform.
    enum uniform = _uniform();

    /// A sampled 2-D image: GLSL's `sampler2D`. Only meaningful in device
    /// code — a `@fragment` function is never compiled for the host.
    struct Sampler2D
    {
        const(void)* handle; ///
    }

    /// An opaque sampler handle. Only meaningful in device code.
    struct SamplerState
    {
        const(void)* handle; ///
    }
}

/**
Names the profiles an entry point, or every entry point of a module, is
built for: `@profiles(vulkan13) @vertex V tri(…)`, or
`@profiles(gl330, gles100) @compute module effects;`. An entry point's own
`@profiles` replaces its module's; one with neither builds for the OpenGL
profiles if it is a fragment entry point, and is an error if it is a vertex
one (`SHC4`).
*/
_profiles profiles(const Profile[] ps...) @safe pure nothrow
{
    string names;
    foreach (i, p; ps)
        names ~= (i ? "," : "") ~ p.name;
    return _profiles(names);
}
