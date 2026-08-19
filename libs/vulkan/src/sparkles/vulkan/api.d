/**
The API-version constants and helpers ImportC cannot supply.

`VK_MAKE_API_VERSION` survives ImportC, but the constants defined in terms of
it — `VK_API_VERSION_1_0` and friends — do not: they are object-like macros
whose body is a call to a function-like macro, which ImportC declines to fold.
They are re-expressed here as `enum`s over the same packing, checked against
`VK_MAKE_API_VERSION` itself so the two cannot disagree.
*/
module sparkles.vulkan.api;

import sparkles.vulkan.vulkan_c;

/// The packed `uint` Vulkan uses for API versions.
uint makeApiVersion(uint variant, uint major, uint minor, uint patch)
    @safe pure nothrow @nogc
    => (variant << 29) | (major << 22) | (minor << 12) | patch;

/// ditto
uint apiVersionVariant(uint packed) @safe pure nothrow @nogc => packed >> 29;
/// ditto
uint apiVersionMajor(uint packed) @safe pure nothrow @nogc => (packed >> 22) & 0x7F;
/// ditto
uint apiVersionMinor(uint packed) @safe pure nothrow @nogc => (packed >> 12) & 0x3FF;
/// ditto
uint apiVersionPatch(uint packed) @safe pure nothrow @nogc => packed & 0xFFF;

enum uint apiVersion10 = makeApiVersion(0, 1, 0, 0); /// `VK_API_VERSION_1_0`
enum uint apiVersion11 = makeApiVersion(0, 1, 1, 0); /// `VK_API_VERSION_1_1`
enum uint apiVersion12 = makeApiVersion(0, 1, 2, 0); /// `VK_API_VERSION_1_2`
enum uint apiVersion13 = makeApiVersion(0, 1, 3, 0); /// `VK_API_VERSION_1_3`
enum uint apiVersion14 = makeApiVersion(0, 1, 4, 0); /// `VK_API_VERSION_1_4`

/**
A packed API version as `"major.minor.patch"`, into `w`.

The variant field is dropped: it is 0 for every Vulkan implementation and
non-zero only for a differently-specified API sharing the encoding, which this
binding does not target.

Written into an output range rather than built with `std.conv.text`, so a
`@nogc` caller can render one into its own buffer — the string form below is
the same digits plus an allocation.

$(B Not for `VkPhysicalDeviceProperties.driverVersion`.) Only `apiVersion` is
guaranteed to use this packing. Vendors encode their driver version how they
like — NVIDIA and Intel both differ — so rendering one through here produces a
plausible and wrong three-part number. Decoding those needs a per-vendor table
keyed on `vendorID`, which this binding does not carry.
*/
void writeApiVersion(Writer)(ref Writer w, uint packed)
{
    import std.range.primitives : put;

    import sparkles.base.text.writers : writeInteger;

    writeInteger(w, apiVersionMajor(packed));
    put(w, '.');
    writeInteger(w, apiVersionMinor(packed));
    put(w, '.');
    writeInteger(w, apiVersionPatch(packed));
}

/// ditto, as a `string`, for a caller that is not holding a buffer.
string formatApiVersion(uint packed) @safe pure nothrow
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // 7-, 10- and 12-bit fields: `127.1023.4095` is the longest possible.
    SmallBuffer!(char, 16) buf;
    writeApiVersion(buf, packed);
    return buf[].idup;
}

@("vulkan.api.writeApiVersionIsNogc")
@safe pure nothrow @nogc unittest
{
    // The reason for the writer form: rendering a version must not force an
    // allocation on a caller that already has a buffer.
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 16) buf;
    buf.writeApiVersion(makeApiVersion(0, 1, 3, 290));
    assert(buf[] == "1.3.290");

    // The widest each field can be: 7, 10 and 12 bits.
    SmallBuffer!(char, 16) widest;
    widest.writeApiVersion(makeApiVersion(0, 127, 1023, 4095));
    assert(widest[] == "127.1023.4095");
}

@("vulkan.api.formatApiVersionRendersTheThreeParts")
@safe pure nothrow unittest
{
    assert(formatApiVersion(apiVersion10) == "1.0.0");
    assert(formatApiVersion(apiVersion13) == "1.3.0");
    assert(formatApiVersion(makeApiVersion(0, 1, 3, 290)) == "1.3.290");

    // Round-trips against the accessors it is built from, including the patch
    // field's full 12-bit range.
    const v = makeApiVersion(0, 1, 4, 4095);
    assert(formatApiVersion(v) == "1.4.4095");

    // The variant is deliberately absent from the rendering.
    assert(formatApiVersion(makeApiVersion(1, 1, 0, 0)) == "1.0.0");
}

/**
The version of the headers this binding was compiled against.

Worth reporting in diagnostics: it is the one number that identifies which
`vulkan.h` produced the struct layouts in `sparkles.vulkan.vulkan_c`.
*/
enum uint headerVersion = VK_HEADER_VERSION;

@("vulkan.api.versionPackingMatchesTheHeader")
@safe pure nothrow @nogc unittest
{
    // `VK_MAKE_API_VERSION` does survive ImportC, so the hand-written packing
    // can be checked against the header's own rather than trusted.
    static assert(apiVersion10 == VK_MAKE_API_VERSION(0, 1, 0, 0));
    static assert(apiVersion11 == VK_MAKE_API_VERSION(0, 1, 1, 0));
    static assert(apiVersion12 == VK_MAKE_API_VERSION(0, 1, 2, 0));
    static assert(apiVersion13 == VK_MAKE_API_VERSION(0, 1, 3, 0));
    static assert(apiVersion14 == VK_MAKE_API_VERSION(0, 1, 4, 0));
}

@("vulkan.api.versionRoundTrip")
@safe pure nothrow @nogc unittest
{
    const v = makeApiVersion(0, 1, 3, 290);
    assert(apiVersionVariant(v) == 0);
    assert(apiVersionMajor(v) == 1);
    assert(apiVersionMinor(v) == 3);
    assert(apiVersionPatch(v) == 290);
}
