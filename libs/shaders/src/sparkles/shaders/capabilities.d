/**
The capabilities a shader target may offer, the profiles that name the
targets, and the active profile of a compilation (`SHC1`–`SHC3`).

A $(I profile) is one output — SPIR-V for an environment, or a shading
language at a version — with the set of capabilities it grants. The build
step compiles a unit once per profile its entry points declare, and in each
compilation the profile is a compile-time fact, $(LREF activeProfile), that
code branches on with `static if`. The table is D data, read the same way by
shader code, by the build step and by tests; the compiler knows only a
profile's name.

This module is compiled for the host and for the device, so it holds no data
a shader would read at run time: profiles and their names are compile-time
constants.
*/
@compute(CompileFor.hostAndDevice) module sparkles.shaders.capabilities;

import sparkles.shaders.attributes : compute, CompileFor;

version (LDC_DCompute)
{
    static import ldc.dcompute;

    /*
    In a device compilation, the compiler's own vocabulary, which it checks a
    grant's names against and reads `@requires` by: the build step passes
    this table's names, so the two are one list.
    */
    alias Cap = ldc.dcompute.Capability;
}
else
{
    /// One thing a target may or may not offer: a stage, a resource lowering,
    /// a type width, an instruction family. In a device compilation, the
    /// compiler's `ldc.dcompute.Capability`, which names the same ones in the
    /// same order.
    enum Cap : int
    {
        /// The SPIR-V `Shader` capability: graphics-stage code at all.
        shader,
        /// The vertex stage.
        vertexStage,
        /// The fragment stage.
        fragmentStage,
        /// Uniforms outside any block, as OpenGL declares them.
        looseUniforms,
        /// Uniform blocks with a binding, as Vulkan declares them.
        uniformBlocks,
        /// Push-constant blocks.
        pushConstants,
        /// Sampled 2-D images read through a sampler.
        sampledImages,
        /// Integer (and integer-vector) vertex inputs.
        intVertexInputs,
        /// 64-bit integers.
        int64,
        /// 16-bit integers.
        int16,
        /// 8-bit integers.
        int8,
        /// 64-bit floats.
        float64,
        /// Buffer device addresses (`PhysicalStorageBuffer`).
        bufferDeviceAddress,
        /// Screen-space derivatives: `dpdx`, `dpdy`, `fwidth`.
        derivatives,
        /// Coarse and fine derivatives: `dpdxCoarse`, `dpdxFine`, ….
        derivativeControl,
        /// Demoting an invocation to a helper: `demote`.
        demote,
    }

    // A host compilation by a compiler that has the vocabulary checks this
    // copy against it.
    static if (__traits(compiles, { import ldc.dcompute : Capability; }))
    {
        static import ldc.dcompute;

        static assert([__traits(allMembers, Cap)] == [__traits(allMembers, ldc.dcompute.Capability)],
            "`Cap` and `ldc.dcompute.Capability` must name the same capabilities, in the same order");
    }
}

/// A capability that implies others: granting it grants them too.
struct Implication
{
    Cap capability; ///
    Cap implied;    ///
}

/// Every implication between capabilities. A profile's set is closed under
/// them.
enum Implication[] implications = [
    Implication(Cap.vertexStage, Cap.shader),
    Implication(Cap.fragmentStage, Cap.shader),
    Implication(Cap.derivativeControl, Cap.derivatives),
];

/// What a profile's output is.
enum Output
{
    /// GLSL for desktop OpenGL, translated from SPIR-V.
    glsl,
    /// GLSL ES, translated from SPIR-V.
    glslEs,
    /// SPIR-V for a Vulkan environment.
    spirv,
    /// The host compilation: no device output.
    host,
}

/// Where a fragment's window position (`Builtin.fragCoord`) has its origin.
enum Origin
{
    /// The profile has no fragment stage.
    none,
    /// The lower-left corner, y up: OpenGL's window coordinates.
    lowerLeft,
    /// The upper-left corner, y down: Vulkan's framebuffer coordinates.
    upperLeft,
}

/// A set of capabilities.
struct CapSet
{
    /// One bit per `Cap`.
    ulong bits;

    /// Whether the set holds `c`.
    bool has(Cap c) const @safe pure nothrow @nogc => (bits & (1UL << c)) != 0;

    /// The set with `c` added.
    CapSet with_(Cap c) const @safe pure nothrow @nogc => CapSet(bits | (1UL << c));
}

/// `caps`, closed under `implications`.
CapSet closure(CapSet caps) @safe pure nothrow @nogc
{
    for (bool changed = true; changed;)
    {
        changed = false;
        foreach (i; implications)
            if (caps.has(i.capability) && !caps.has(i.implied))
            {
                caps = caps.with_(i.implied);
                changed = true;
            }
    }
    return caps;
}

/// The set of `caps`, closed under `implications`.
CapSet capsOf(Cap[] caps...) @safe pure nothrow @nogc
{
    CapSet r;
    foreach (c; caps)
        r = r.with_(c);
    return closure(r);
}

/// A named output and the capabilities it grants.
struct Profile
{
    /// The D identifier `@profiles` names it by: `vulkan13`.
    string identifier;
    /// The name used on the command line, in the manifest and in
    /// diagnostics: `vulkan1.3`.
    string name;
    /// What the output is.
    Output output;
    /// The output's version: GLSL's (`330`, `100`), or the Vulkan
    /// environment's (`13` for Vulkan 1.3).
    uint version_;
    /// The capabilities it grants, closed under `implications`.
    CapSet caps;
    /// Where its fragments' window positions have their origin.
    Origin fragCoordOrigin;

    /// Whether the profile grants `c`.
    bool has(Cap c) const @safe pure nothrow @nogc => caps.has(c);
}

/// OpenGL 3.3: GLSL 3.30, fragment shaders, uniforms outside blocks, and
/// derivatives, but not coarse and fine ones (OpenGL 4.5).
enum Profile gl330 = Profile("gl330", "gl330", Output.glsl, 330,
    capsOf(Cap.fragmentStage, Cap.looseUniforms, Cap.sampledImages, Cap.derivatives),
    Origin.lowerLeft);

/// OpenGL ES 2.0: GLSL ES 1.00, fragment shaders, uniforms outside blocks.
/// Denies derivatives, which ES 2.0 offers only as an extension.
enum Profile gles100 = Profile("gles100", "gles100", Output.glslEs, 100,
    capsOf(Cap.fragmentStage, Cap.looseUniforms, Cap.sampledImages), Origin.lowerLeft);

/// Vulkan 1.3: SPIR-V 1.6, vertex and fragment shaders, uniform and
/// push-constant blocks, derivatives of every kind, and demotion. Denies
/// `int64`, which Vulkan grants only with a device feature.
enum Profile vulkan13 = Profile("vulkan13", "vulkan1.3", Output.spirv, 13,
    capsOf(Cap.vertexStage, Cap.fragmentStage, Cap.uniformBlocks, Cap.pushConstants,
        Cap.sampledImages, Cap.intVertexInputs, Cap.derivativeControl, Cap.demote),
    Origin.upperLeft);

/// Vulkan 1.1: SPIR-V 1.3, which every Vulkan 1.1 device consumes, and so the
/// floor of Android's `VP_ANDROID_baseline_2022`. What `vulkan13` grants, but
/// demotion, which SPIR-V 1.3 has only as an extension.
enum Profile vulkan11 = Profile("vulkan11", "vulkan1.1", Output.spirv, 11,
    capsOf(Cap.vertexStage, Cap.fragmentStage, Cap.uniformBlocks, Cap.pushConstants,
        Cap.sampledImages, Cap.intVertexInputs, Cap.derivativeControl),
    Origin.upperLeft);

/// The host compilation: every resource kind as plain D values, no stage.
enum Profile cpu = Profile("cpu", "cpu", Output.host, 0,
    capsOf(Cap.looseUniforms, Cap.uniformBlocks, Cap.pushConstants, Cap.int64,
        Cap.int16, Cap.int8, Cap.float64), Origin.none);

/// Every profile, in the table's order: the order the build step compiles
/// them in.
enum Profile[] allProfiles = [gl330, gles100, vulkan13, vulkan11, cpu];

/// The profile named `name`; a name not in the table fails the compilation,
/// naming it.
template profileNamed(string name)
{
    enum index = () {
        foreach (i, p; allProfiles)
            if (p.name == name)
                return cast(ptrdiff_t) i;
        return -1;
    }();
    static assert(index >= 0, "`" ~ name ~ "` is not a shader profile; the profiles are "
        ~ () {
            string r;
            foreach (i, p; allProfiles)
                r ~= (i ? ", `" : "`") ~ p.name ~ "`";
            return r;
        }());
    enum profileNamed = allProfiles[index];
}

static if (__traits(compiles, __traits(getTargetInfo, "shaderProfile")))
    private enum activeProfileName = __traits(getTargetInfo, "shaderProfile");
else
    private enum activeProfileName = "cpu";

static if (activeProfileName == "manifest")
{
    /*
    While the build step lists entry points (the manifest), no profile is
    active, and reading one fails, however it is read: an entry point's
    existence and its `@profiles` must not depend on the profile (`SHC5`).
    Function bodies are not analysed then, so a body that branches on the
    profile compiles.
    */
    Profile activeProfile()()
    {
        static assert(0, "`activeProfile` is not available while the build step lists entry " ~
            "points (the manifest): an entry point's existence and its `@profiles` must not " ~
            "depend on the profile; branch on it inside a function body instead");
    }
}
else
{
    /**
    The profile of this compilation: the one the build step compiles the unit
    for (`-mdcompute-profile`), or `cpu` in a host compilation and under a
    compiler that does not know profiles (DMD, a stock LDC).
    */
    enum Profile activeProfile = profileNamed!(activeProfileName.length ? activeProfileName : "cpu");
}

/// A SPIR-V capability or extension and the capability it belongs to.
struct SpirvRequirement
{
    /// The capability's or extension's name, as `OpCapability` and
    /// `OpExtension` spell it.
    string spirv;
    /// The capability a profile must grant for a module to declare it.
    Cap capability;
}

/**
What each `OpCapability` and `OpExtension` a module may declare belongs to.
The build step's audit (`SHC9`) fails a module that declares one its profile
does not grant, or one this table does not list.
*/
enum SpirvRequirement[] spirvRequirements = [
    SpirvRequirement("Shader", Cap.shader),
    SpirvRequirement("Int64", Cap.int64),
    SpirvRequirement("Int16", Cap.int16),
    SpirvRequirement("Int8", Cap.int8),
    SpirvRequirement("Float64", Cap.float64),
    SpirvRequirement("PhysicalStorageBufferAddresses", Cap.bufferDeviceAddress),
    SpirvRequirement("SPV_KHR_physical_storage_buffer", Cap.bufferDeviceAddress),
    SpirvRequirement("DerivativeControl", Cap.derivativeControl),
    SpirvRequirement("DemoteToHelperInvocation", Cap.demote),
    SpirvRequirement("SPV_EXT_demote_to_helper_invocation", Cap.demote),
];

version (LDC_DCompute)
{
    /*
    The compiler's: an emitted entry point that reaches a function marked
    `@requires(c)`, or a call of `unsupported!c`, fails the compilation unless
    it is granted `c`, and the compiler names the chain of calls (`SHC8`).
    */
    public import ldc.dcompute : requires, _requires, unsupported;
}
else
{
    /// What `@requires` makes of its capabilities. Stand-in for
    /// `ldc.dcompute._requires`.
    struct _requires
    {
        Cap[] capabilities; ///
    }

    /// Marks a function as needing `capabilities` (`SHC7`). Stand-in for
    /// `ldc.dcompute.requires`: nothing checks it outside a device compilation.
    _requires requires(Cap[] capabilities...) @safe pure nothrow => _requires(capabilities.dup);

    /**
    What a function that needs `c` compiles to where the active profile lacks
    it. Here, outside a device compilation, nothing can check that no caller
    reaches it, so a call is an error at run time, naming the capability.
    */
    noreturn unsupported(Cap c, T...)(T args)
    {
        enum message = "`" ~ __traits(allMembers, Cap)[c] ~ "` is not granted by the profile `"
            ~ activeProfile.name ~ "`";
        assert(0, message);
    }
}
