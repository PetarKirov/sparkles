/**
SPIR-V as `vkCreateShaderModule` takes it: 32-bit words, aligned.
*/
module sparkles.vulkan.spirv;

/**
SPIR-V as 32-bit words, assembled at compile time.

`VkShaderModuleCreateInfo.pCode` is a `const uint32_t*`, and a string import is
bytes whose alignment D does not promise — casting the pointer would be
undefined behaviour that happens to work. Building the words in CTFE puts a
correctly aligned `uint[]` in `.rodata` instead, at no runtime cost.
*/
immutable(uint)[] spirvWords(string bytes) @safe pure nothrow
{
    assert(bytes.length % 4 == 0, "SPIR-V is a stream of 32-bit words");

    auto words = new uint[bytes.length / 4];
    foreach (i, ref w; words)
        w = (cast(uint) cast(ubyte) bytes[i * 4])
            | (cast(uint) cast(ubyte) bytes[i * 4 + 1]) << 8
            | (cast(uint) cast(ubyte) bytes[i * 4 + 2]) << 16
            | (cast(uint) cast(ubyte) bytes[i * 4 + 3]) << 24;
    return words.idup;
}

/// SPIR-V's magic number, the first word of every module: a corrupt or
/// truncated blob checked against it is a compile error rather than a driver
/// crash.
enum uint spirvMagic = 0x0723_0203;

///
@("vulkan.spirv.wordsAreLittleEndian")
@safe pure nothrow unittest
{
    enum words = spirvWords("\x03\x02\x23\x07\x00\x00\x01\x00");
    static assert(words == [spirvMagic, 0x0001_0000]);
}
