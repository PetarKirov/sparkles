/**
What a module that also compiles for a GPU is written against.

In a dcompute build (`LDC_DCompute`) these are LDC's `ldc.dcompute` symbols,
which the compiler recognises: `@compute` on a module makes it device code,
and `@vectorType` on a struct whose only field is a `__vector` makes the
struct that vector wherever it crosses a shader's interface. Without the
version they are inert stand-ins with the same names and shapes, so the same
source compiles as ordinary D on any compiler.
*/
module sparkles.math.device;

version (LDC_DCompute)
{
    public import ldc.dcompute : compute, CompileFor, vectorType;
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

    /// Marks a module as device code. Stand-in for `ldc.dcompute.compute`.
    struct compute
    {
        CompileFor codeProduction = CompileFor.deviceOnly; ///
    }

    private struct _vectorType {}

    /// Marks a struct as the vector it holds at a shader's interface.
    /// Stand-in for `ldc.dcompute.vectorType`.
    enum vectorType = _vectorType();
}
