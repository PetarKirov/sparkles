/**
The interface of a fragment module, read from its SPIR-V: what an effect
pass's artifact asks of the pipeline that runs it (`UVK15`).

An effect record carries its Vulkan passes as SPIR-V bytes and nothing
else (`EFX13`): the toolkit never looks inside, so the backend that runs
them has to. This reads the few things a pipeline needs — the entry point,
the input locations by name, each descriptor's binding and kind, and the
default uniform block's members with their offsets — from the module's
debug names and decorations, which `shader-compile` always emits (`SHR8`).
*/
module sparkles.ui_vulkan.spirv_interface;

import sparkles.vulkan.spirv : spirvMagic;

@safe pure nothrow:

/// What a descriptor binding holds.
enum DescriptorKind : ubyte
{
    sampler,      /// a `SamplerState`, or the shared sampler
    sampledImage, /// a `Sampler2D`'s image
    uniformBlock, /// a uniform buffer
}

/// One descriptor of set 0.
struct InterfaceBinding
{
    string name;         /// the variable's name: `texture0`, `sampler`, `crtTubeUniforms`
    uint binding;        ///
    DescriptorKind kind; ///
}

/// One member of the uniform block.
struct BlockMember
{
    string name; /// the `@uniform` parameter's name
    uint offset; /// bytes from the block's start (`std140`)
    uint size;   /// bytes: 4 for a scalar, 4·n for a vector of n
}

/// A fragment module's interface, as far as an effect pass needs it.
struct FragmentInterface
{
    string entry;               /// the fragment entry point's name
    InterfaceBinding[] bindings; /// set 0, in declaration order
    BlockMember[] members;      /// the uniform block's, in member order
    uint blockBinding = uint.max; /// the uniform block's binding; `uint.max` for none
    uint blockSize;             /// its size in bytes, rounded up to 16

    /// The location input `name` is read from, or -1 if the module reads none.
    int inputLocation(scope const(char)[] name) const @safe pure nothrow @nogc
    {
        foreach (ref i; inputs_)
            if (i.name == name)
                return cast(int) i.location;
        return -1;
    }

    /// The binding of the variable named `name`, or `uint.max`.
    uint bindingOf(scope const(char)[] name) const @safe pure nothrow @nogc
    {
        foreach (ref b; bindings)
            if (b.name == name)
                return b.binding;
        return uint.max;
    }

    private static struct Input
    {
        string name;
        uint location;
    }

    private Input[] inputs_;
}

/**
The interface of the first fragment entry point in `words`, or `false` if
they are not a module this can read: no magic number, a malformed
instruction, no fragment entry point, or a descriptor outside set 0.
*/
bool readFragmentInterface(scope const(uint)[] words, out FragmentInterface result)
{
    enum : ushort
    {
        opName = 5, opMemberName = 6, opEntryPoint = 15, opTypeInt = 21,
        opTypeFloat = 22, opTypeVector = 23, opTypeImage = 25, opTypeSampler = 26,
        opTypeStruct = 30, opTypePointer = 32, opVariable = 59, opDecorate = 71,
        opMemberDecorate = 72,
    }
    enum : uint
    {
        decoBlock = 2, decoLocation = 30, decoBinding = 33, decoDescriptorSet = 34,
        decoOffset = 35,
    }
    enum : uint { storageUniformConstant = 0, storageInput = 1, storageUniform = 2 }
    enum uint executionFragment = 4;

    static struct Id
    {
        string name;
        uint location = uint.max, binding = uint.max, set;
        ushort typeOp;           // the type instruction that defined the id
        uint size;               // a scalar's or vector's size in bytes
        uint pointee, storage;   // a pointer type's
        uint[] memberTypes;      // a struct's
        string[] memberNames;
        uint[] memberOffsets;
        uint varType, varStorage; // a variable's
        bool variable, block;
    }

    if (words.length < 5 || words[0] != spirvMagic)
        return false;
    const bound = words[3];
    if (bound == 0 || bound > 1 << 22)
        return false;
    auto ids = new Id[bound];
    bool inBounds(uint id) => id < ids.length;

    static string literal(scope const(uint)[] w)
    {
        char[] s;
        foreach (word; w)
            foreach (shift; [0, 8, 16, 24])
            {
                const c = cast(char)((word >> shift) & 0xFF);
                if (c == 0)
                    return s.idup;
                s ~= c;
            }
        return s.idup;
    }

    static void grow(T)(ref T[] a, size_t n)
    {
        if (a.length < n)
            a.length = n;
    }

    uint entryId = uint.max;
    for (size_t at = 5; at < words.length;)
    {
        const count = words[at] >> 16;
        const op = cast(ushort)(words[at] & 0xFFFF);
        if (count == 0 || at + count > words.length)
            return false;
        const w = words[at + 1 .. at + count];
        at += count;
        switch (op)
        {
            case opEntryPoint:
                if (w.length >= 3 && w[0] == executionFragment && entryId == uint.max
                    && inBounds(w[1]))
                {
                    entryId = w[1];
                    result.entry = literal(w[2 .. $]);
                }
                break;
            case opName:
                if (w.length >= 2 && inBounds(w[0]))
                    ids[w[0]].name = literal(w[1 .. $]);
                break;
            case opMemberName:
                if (w.length >= 3 && inBounds(w[0]))
                {
                    grow(ids[w[0]].memberNames, w[1] + 1);
                    ids[w[0]].memberNames[w[1]] = literal(w[2 .. $]);
                }
                break;
            case opDecorate:
                if (w.length >= 2 && inBounds(w[0]))
                {
                    auto d = &ids[w[0]];
                    if (w[1] == decoBlock)
                        d.block = true;
                    else if (w.length >= 3 && w[1] == decoLocation)
                        d.location = w[2];
                    else if (w.length >= 3 && w[1] == decoBinding)
                        d.binding = w[2];
                    else if (w.length >= 3 && w[1] == decoDescriptorSet)
                        d.set = w[2];
                }
                break;
            case opMemberDecorate:
                if (w.length >= 4 && inBounds(w[0]) && w[2] == decoOffset)
                {
                    grow(ids[w[0]].memberOffsets, w[1] + 1);
                    ids[w[0]].memberOffsets[w[1]] = w[3];
                }
                break;
            case opTypeInt:
            case opTypeFloat:
                if (w.length >= 2 && inBounds(w[0]))
                {
                    ids[w[0]].typeOp = op;
                    ids[w[0]].size = w[1] / 8;
                }
                break;
            case opTypeVector:
                if (w.length >= 3 && inBounds(w[0]) && inBounds(w[1]))
                {
                    ids[w[0]].typeOp = op;
                    ids[w[0]].size = ids[w[1]].size * w[2];
                }
                break;
            case opTypeImage:
            case opTypeSampler:
                if (w.length >= 1 && inBounds(w[0]))
                    ids[w[0]].typeOp = op;
                break;
            case opTypeStruct:
                if (w.length >= 1 && inBounds(w[0]))
                {
                    ids[w[0]].typeOp = op;
                    ids[w[0]].memberTypes = w[1 .. $].dup;
                }
                break;
            case opTypePointer:
                if (w.length >= 3 && inBounds(w[0]))
                {
                    ids[w[0]].typeOp = op;
                    ids[w[0]].storage = w[1];
                    ids[w[0]].pointee = w[2];
                }
                break;
            case opVariable:
                if (w.length >= 3 && inBounds(w[0]) && inBounds(w[1]))
                {
                    ids[w[1]].variable = true;
                    ids[w[1]].varType = w[0];
                    ids[w[1]].varStorage = w[2];
                }
                break;
            default:
                break;
        }
    }
    if (entryId == uint.max)
        return false;

    foreach (ref v; ids)
    {
        if (!v.variable || !inBounds(v.varType) || !inBounds(ids[v.varType].pointee))
            continue;
        const pointee = &ids[ids[v.varType].pointee];
        if (v.varStorage == storageInput && v.location != uint.max)
            result.inputs_ ~= FragmentInterface.Input(v.name, v.location);
        if ((v.varStorage != storageUniformConstant && v.varStorage != storageUniform)
            || v.binding == uint.max)
            continue;
        if (v.set != 0)
            return false;
        DescriptorKind kind;
        if (pointee.typeOp == opTypeSampler)
            kind = DescriptorKind.sampler;
        else if (pointee.typeOp == opTypeImage)
            kind = DescriptorKind.sampledImage;
        else if (pointee.typeOp == opTypeStruct && pointee.block)
        {
            kind = DescriptorKind.uniformBlock;
            if (result.blockBinding != uint.max)
                return false; // one default block per entry point (`SHR3`)
            result.blockBinding = v.binding;
            uint end;
            foreach (m, type; pointee.memberTypes)
            {
                if (m >= pointee.memberNames.length || m >= pointee.memberOffsets.length
                    || !inBounds(type))
                    return false;
                const member = BlockMember(pointee.memberNames[m], pointee.memberOffsets[m],
                    ids[type].size);
                result.members ~= member;
                if (member.offset + member.size > end)
                    end = member.offset + member.size;
            }
            result.blockSize = (end + 15) & ~15u;
        }
        else
            return false;
        result.bindings ~= InterfaceBinding(v.name, v.binding, kind);
    }
    return true;
}

version (unittest)
{
    import sparkles.ui.effect : generatedEffect, hasGpuEffects, vulkan11Backend,
        vulkan13Backend;
    import sparkles.vulkan.spirv : spirvWords;
}

@("ui_vulkan.spirv_interface.readsTheCrtTube")
@safe pure nothrow unittest
{
    static assert(hasGpuEffects, "ui-vulkan selects sparkles:ui's gpu-effects configuration");
    foreach (key; [vulkan13Backend, vulkan11Backend])
    {
        FragmentInterface fi;
        assert(readFragmentInterface(spirvWords(generatedEffect!"crtTube"(key)), fi), key);
        assert(fi.entry == "crtTube");
        // The varyings raylib's vertex shader emits, where `effectVertex` writes them.
        assert(fi.inputLocation("fragTexCoord") == 0 && fi.inputLocation("fragColor") == 1);
        assert(fi.inputLocation("nothing") == -1);
        // The shared sampler, the two images, then the default block (`SHR7`).
        assert(fi.bindingOf("sampler") == 0);
        assert(fi.bindingOf("texture0") == 1 && fi.bindingOf("texture1") == 2);
        assert(fi.blockBinding == 3);
        // `std140`, the parameters' names and order: `colDiffuse` a vec4 at
        // 0, `uResolution` a vec2 at 16, `uTime` at 24.
        assert(fi.members[0] == BlockMember("colDiffuse", 0, 16));
        assert(fi.members[1] == BlockMember("uResolution", 16, 8));
        assert(fi.members[2] == BlockMember("uTime", 24, 4));
        assert(fi.members[$ - 1].name == "uScrollbarThumb" && fi.members[$ - 1].size == 16);
        assert(fi.blockSize % 16 == 0 && fi.blockSize >= fi.members[$ - 1].offset + 16);
    }
}

@("ui_vulkan.spirv_interface.refusesWhatIsNotAModule")
@safe pure nothrow unittest
{
    FragmentInterface fi;
    assert(!readFragmentInterface(null, fi));
    assert(!readFragmentInterface([1u, 2, 3, 4, 5], fi), "no magic number");
    // A header and one instruction claiming more words than there are.
    assert(!readFragmentInterface([spirvMagic, 0x00010600, 0, 8, 0, (9u << 16) | 5], fi));
    // A well-formed module with no fragment entry point.
    assert(!readFragmentInterface([spirvMagic, 0x00010600, 0, 8, 0], fi));
}
