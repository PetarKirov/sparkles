/**
The API-version constants and helpers ImportC cannot supply.

`VK_MAKE_API_VERSION` survives ImportC, but the constants defined in terms of
it — `VK_API_VERSION_1_0` and friends — do not: they are object-like macros
whose body is a call to a function-like macro, which ImportC declines to fold.
They are re-expressed here as `enum`s over the same packing, checked against
`VK_MAKE_API_VERSION` itself so the two cannot disagree.
*/
module sparkles.vulkan.api;

import sparkles.vulkan.c;

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
The version of the headers this binding was compiled against.

Worth reporting in diagnostics: it is the one number that identifies which
`vulkan.h` produced the struct layouts in `sparkles.vulkan.c`.
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
