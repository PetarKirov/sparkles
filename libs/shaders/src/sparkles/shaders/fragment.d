/**
The fragment stage's operations: derivatives, and the three ways a fragment
invocation stops contributing.

Each needs the fragment stage and a capability (`SHC7`), and declares both
with `@requires`, so a device compilation fails when an entry point it emits
reaches one without being granted them, and names the chain of calls
(`SHC8`). Where the active profile lacks the capability, the body is
`unsupported!c` instead: a function no emitted entry point reaches is still
compiled for every profile of its unit (`SHC6`).

$(UL
    $(LI $(B Derivatives) are the rate of change of a value across a 2×2 quad
        of fragments, in window x and y. `dpdx`, `dpdy` and `fwidth` leave the
        precision to the target (`derivatives`); the `Coarse` forms may share
        one value across the quad, and the `Fine` forms compute one per
        fragment (`derivativeControl`).)
    $(LI $(B `terminate`) ends the invocation: nothing after it runs, and it
        writes nothing.)
    $(LI $(B `demote`) makes it a helper invocation: it keeps running, so the
        quad's derivatives stay defined, but writes nothing (`demote`).)
    $(LI $(B `discard`) is `terminate` on every profile, as GLSL's `discard`
        is, so it means one thing in every output; a shader that needs its
        quad's derivatives after discarding demotes instead.))

On the host (`cpu`), no profile grants the fragment stage until the reference
executor, and each of them stops the program, naming the capability.
*/
@compute(CompileFor.hostAndDevice) module sparkles.shaders.fragment;

import sparkles.shaders.attributes : compute, CompileFor;
import sparkles.shaders.capabilities : activeProfile, Cap, requires, unsupported;
import sparkles.shaders.math : abs;
import sparkles.shaders.types : isShaderVector;

version (LDC_DCompute)
{
    pragma(LDC_intrinsic, "llvm.spv.ddx.f#") T spvDdx(T)(T v);
    pragma(LDC_intrinsic, "llvm.spv.ddy.f#") T spvDdy(T)(T v);
    pragma(LDC_intrinsic, "llvm.spv.fwidth.f#") T spvFwidth(T)(T v);
    pragma(LDC_intrinsic, "llvm.spv.ddx.coarse.f#") T spvDdxCoarse(T)(T v);
    pragma(LDC_intrinsic, "llvm.spv.ddy.coarse.f#") T spvDdyCoarse(T)(T v);
    pragma(LDC_intrinsic, "llvm.spv.ddx.fine.f#") T spvDdxFine(T)(T v);
    pragma(LDC_intrinsic, "llvm.spv.ddy.fine.f#") T spvDdyFine(T)(T v);
    pragma(LDC_intrinsic, "llvm.spv.terminate.invocation") void spvTerminate();
    // At SPIR-V 1.6 the backend lowers it to `OpDemoteToHelperInvocation`.
    pragma(LDC_intrinsic, "llvm.spv.discard") void spvDemote();

    import ldc.dcompute : __dcompute_reflect, ReflectTarget;

    /*
    A device compilation compiles a host-and-device module for the host too,
    into an object the build step discards, and the host's backend has no
    SPIR-V intrinsics: the call is generated for the device only (LDC picks
    the branch of a `__dcompute_reflect` test per target).
    */
    T onDevice(alias intrinsic, T)(T v)
    {
        if (__dcompute_reflect(ReflectTarget.Vulkan))
            return intrinsic(v);
        else
            return v;
    }

    /// ditto
    void onDevice(alias intrinsic)()
    {
        if (__dcompute_reflect(ReflectTarget.Vulkan))
            intrinsic();
    }
}

/// A `float` or a vector of them: what a derivative takes.
enum isDerivable(T) = is(T == float) || isShaderVector!T;

/// The rate of change of `v` in window x, across the fragment's quad.
@requires(Cap.fragmentStage, Cap.derivatives)
T dpdx(T)(in T v)
if (isDerivable!T)
{
    static if (activeProfile.has(Cap.derivatives))
        return onDevice!spvDdx(v);
    else
        return unsupported!(Cap.derivatives)(v);
}

/// The rate of change of `v` in window y, across the fragment's quad.
@requires(Cap.fragmentStage, Cap.derivatives)
T dpdy(T)(in T v)
if (isDerivable!T)
{
    static if (activeProfile.has(Cap.derivatives))
        return onDevice!spvDdy(v);
    else
        return unsupported!(Cap.derivatives)(v);
}

/// `abs(dpdx(v)) + abs(dpdy(v))`: how fast `v` changes per fragment.
@requires(Cap.fragmentStage, Cap.derivatives)
T fwidth(T)(in T v)
if (isDerivable!T)
{
    static if (activeProfile.has(Cap.derivatives))
        return onDevice!spvFwidth(v);
    else
        return unsupported!(Cap.derivatives)(v);
}

/// `dpdx`, possibly one value for the whole quad.
@requires(Cap.fragmentStage, Cap.derivativeControl)
T dpdxCoarse(T)(in T v)
if (isDerivable!T)
{
    static if (activeProfile.has(Cap.derivativeControl))
        return onDevice!spvDdxCoarse(v);
    else
        return unsupported!(Cap.derivativeControl)(v);
}

/// `dpdy`, possibly one value for the whole quad.
@requires(Cap.fragmentStage, Cap.derivativeControl)
T dpdyCoarse(T)(in T v)
if (isDerivable!T)
{
    static if (activeProfile.has(Cap.derivativeControl))
        return onDevice!spvDdyCoarse(v);
    else
        return unsupported!(Cap.derivativeControl)(v);
}

/// `abs(dpdxCoarse(v)) + abs(dpdyCoarse(v))`.
@requires(Cap.fragmentStage, Cap.derivativeControl)
T fwidthCoarse(T)(in T v)
if (isDerivable!T)
    => abs(dpdxCoarse(v)) + abs(dpdyCoarse(v));

/// `dpdx`, computed for this fragment from its neighbour in the quad.
@requires(Cap.fragmentStage, Cap.derivativeControl)
T dpdxFine(T)(in T v)
if (isDerivable!T)
{
    static if (activeProfile.has(Cap.derivativeControl))
        return onDevice!spvDdxFine(v);
    else
        return unsupported!(Cap.derivativeControl)(v);
}

/// `dpdy`, computed for this fragment from its neighbour in the quad.
@requires(Cap.fragmentStage, Cap.derivativeControl)
T dpdyFine(T)(in T v)
if (isDerivable!T)
{
    static if (activeProfile.has(Cap.derivativeControl))
        return onDevice!spvDdyFine(v);
    else
        return unsupported!(Cap.derivativeControl)(v);
}

/// `abs(dpdxFine(v)) + abs(dpdyFine(v))`.
@requires(Cap.fragmentStage, Cap.derivativeControl)
T fwidthFine(T)(in T v)
if (isDerivable!T)
    => abs(dpdxFine(v)) + abs(dpdyFine(v));

/// Ends the invocation: nothing after it runs, and the fragment is not
/// written. GLSL's `discard`; SPIR-V's `OpTerminateInvocation`.
@requires(Cap.fragmentStage)
void terminate()()
{
    static if (activeProfile.has(Cap.fragmentStage))
        onDevice!spvTerminate();
    else
        unsupported!(Cap.fragmentStage)();
}

/// `terminate`, on every profile: what GLSL's `discard` means.
@requires(Cap.fragmentStage)
void discard()() => terminate();

/// Makes the invocation a helper: it keeps running, so its quad's
/// derivatives stay defined, but the fragment is not written. SPIR-V's
/// `OpDemoteToHelperInvocation`.
@requires(Cap.fragmentStage, Cap.demote)
void demote()()
{
    static if (activeProfile.has(Cap.demote))
        onDevice!spvDemote();
    else
        unsupported!(Cap.demote)();
}
