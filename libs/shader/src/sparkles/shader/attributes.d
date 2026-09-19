/**
The attributes and opaque handles a shader module is written against.

Under `-d-version=SparklesShaderDevice` these are LDC's `ldc.dcompute`
symbols, which the compiler recognises: `@compute` on a module makes it
device code, `@fragment` on a function makes it a fragment-shader entry
point, and the parameter markers and `Sampler2D` describe the interface the
compiler synthesises around it. Without the version they are inert stand-ins
with the same names and shapes, so the same source compiles as ordinary D on
any compiler.
*/
module sparkles.shader.attributes;

version (SparklesShaderDevice)
{
    public import ldc.dcompute : compute, CompileFor, fragment, input, uniform,
        Sampler, Sampler2D, sample;
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
    struct Sampler
    {
        const(void)* handle; ///
    }
}
