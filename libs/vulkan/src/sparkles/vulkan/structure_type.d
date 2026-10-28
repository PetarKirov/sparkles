/**
Automatic `sType` initialisation.

Every Vulkan `*CreateInfo` carries an `sType` enumerator that must match its own
type, and getting it wrong is a whole class of validation error
(`VUID-*-sType-sType`). C cannot default it — there are no default member
initialisers — so callers set it by hand, 666 times, and a copy-pasted struct
declaration silently keeps the wrong tag.

The name is mechanically derivable, so derive it: `VkInstanceCreateInfo` is
always tagged `VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO`. $(LREF structureTypeOf)
does that transform at compile time and looks the enumerator up in
`VkStructureType`, so a struct that does not follow the convention is a
compile error naming the enumerator it looked for — never a silently mistagged
value reaching the driver.

The research catalog records `sType` defaulting as the single biggest
ergonomic win ErupteD had over both C and raw ImportC, at zero runtime cost
($(LINK2 ../../../docs/research/vulkan/d-erupted.md, `d-erupted.md`)).
*/
module sparkles.vulkan.structure_type;

import std.traits : EnumMembers;

import sparkles.vulkan.vulkan_c;
import sparkles.vulkan.platform;

/**
The `VK_STRUCTURE_TYPE_*` enumerator belonging to `T`.

$(LREF upperSnake) derives it for the regular names. Vulkan does not split
every digit or acronym the same way — `VkVideoDecodeH264ProfileInfoKHR` is
`..._H264_PROFILE_INFO_KHR`, `VkPhysicalDeviceTextureCompressionASTCHDRFeatures`
is `..._ASTC_HDR_FEATURES`, `VkWin32SurfaceCreateInfoKHR` is `..._WIN32_...` —
so when the derived name is absent, the enumerator is the one member whose
spelling without underscores is the type's name in upper case. Two such members
are a compile error, never a guess.

Compile error if `T` is not a `Vk`-prefixed struct, or if no enumerator matches.
*/
template structureTypeOf(T)
{
    static assert(is(T == struct), T.stringof ~ " is not a struct");
    static assert(T.stringof.length > 2 && T.stringof[0 .. 2] == "Vk",
        T.stringof ~ " is not a Vk* type");

    private enum derived = "VK_STRUCTURE_TYPE_" ~ upperSnake(T.stringof[2 .. $]);
    static if (__traits(hasMember, VkStructureType, derived))
        private enum name = derived;
    else
        private enum name = matchingStructureType(T.stringof[2 .. $]);

    static assert(name.length && name[0] != '!',
        "no unique `VK_STRUCTURE_TYPE_*` for " ~ T.stringof ~ " (tried `" ~ derived
            ~ "` and an underscore-insensitive match)" ~ (name.length ? ": " ~ name[1 .. $] : ""));

    enum VkStructureType structureTypeOf = __traits(getMember, VkStructureType, name);
}

private immutable string[] structureTypeNames = [__traits(allMembers, VkStructureType)];
private immutable VkStructureType[] structureTypeValues = [EnumMembers!VkStructureType];

/**
The `VkStructureType` member spelled `VK_STRUCTURE_TYPE_` plus `name` in upper
case once underscores are ignored; empty when none is, and `!` followed by the
candidates when several are and their values differ. Legacy aliases share a
value with the member they alias (`SURFACE_CAPABILITIES2_EXT` and
`SURFACE_CAPABILITIES_2_EXT`), so they are not a conflict.
*/
private string matchingStructureType(string name) @safe pure nothrow
{
    static string squash(string s) @safe pure nothrow
    {
        string r;
        foreach (char c; s)
            if (c != '_')
                r ~= isLower(c) ? cast(char)(c - 'a' + 'A') : c;
        return r;
    }

    const want = "VKSTRUCTURETYPE" ~ squash(name);
    string found;
    size_t foundAt;
    foreach (i, m; structureTypeNames)
        if (squash(m) == want)
        {
            if (!found.length)
            {
                found = m;
                foundAt = i;
            }
            else if (structureTypeValues[i] != structureTypeValues[foundAt])
                return "!" ~ found ~ ", " ~ m;
        }
    return found;
}

/**
`InstanceCreateInfo` → `INSTANCE_CREATE_INFO`, following Vulkan's own naming.

A separator goes before an upper-case letter that begins a word — one that
follows a lower-case letter or digit, or that is the last capital of a run and
is followed by a lower-case letter — and before every digit, so acronyms stay
whole (`...InfoKHR` → `..._INFO_KHR`, `DeviceIDProperties` →
`DEVICE_ID_PROPERTIES`) while version digits separate individually
(`Vulkan11Features` → `VULKAN_1_1_FEATURES`).
*/
string upperSnake(string camel) @safe pure nothrow
{
    string result;
    foreach (i, char c; camel)
    {
        const prev = i > 0 ? camel[i - 1] : '\0';
        const next = i + 1 < camel.length ? camel[i + 1] : '\0';

        bool separate;
        if (isDigit(c))
            separate = i > 0;
        else if (isUpper(c) && i > 0)
            separate = isLower(prev) || isDigit(prev) || (isUpper(prev) && isLower(next));

        if (separate)
            result ~= '_';
        result ~= isLower(c) ? cast(char)(c - 'a' + 'A') : c;
    }
    return result;
}

private bool isUpper(char c) @safe pure nothrow @nogc => c >= 'A' && c <= 'Z';
private bool isLower(char c) @safe pure nothrow @nogc => c >= 'a' && c <= 'z';
private bool isDigit(char c) @safe pure nothrow @nogc => c >= '0' && c <= '9';

/**
`value` with its `sType` set correctly.

Named-argument construction stays available, so the call reads as the struct it
is and nothing has to remember the tag:

---
auto ci = vkInfo(VkInstanceCreateInfo(pApplicationInfo: &appInfo));
---
*/
T vkInfo(T)(T value = T.init) @safe pure nothrow @nogc
{
    value.sType = structureTypeOf!T;
    return value;
}

@("vulkan.structure_type.upperSnake")
@safe pure unittest
{
    assert(upperSnake("InstanceCreateInfo") == "INSTANCE_CREATE_INFO");
    assert(upperSnake("SwapchainCreateInfoKHR") == "SWAPCHAIN_CREATE_INFO_KHR");
    assert(upperSnake("DebugUtilsMessengerCreateInfoEXT")
        == "DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT");
    // Acronym followed by a word: the run stays whole, the next word splits.
    assert(upperSnake("PhysicalDeviceIDProperties") == "PHYSICAL_DEVICE_ID_PROPERTIES");
    // Digits separate one at a time, which is how Vulkan spells versions.
    assert(upperSnake("PhysicalDeviceFeatures2") == "PHYSICAL_DEVICE_FEATURES_2");
    assert(upperSnake("PhysicalDeviceVulkan11Features") == "PHYSICAL_DEVICE_VULKAN_1_1_FEATURES");
}

@("vulkan.structure_type.derivesTheRightEnumerator")
@safe pure nothrow @nogc unittest
{
    // The transform is only worth having if it agrees with the header for the
    // shapes this library actually passes to the driver — plain create-infos,
    // an extension-suffixed one, a digit-suffixed one, and a version struct.
    static assert(structureTypeOf!VkInstanceCreateInfo
        == VkStructureType.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO);
    static assert(structureTypeOf!VkDeviceCreateInfo
        == VkStructureType.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO);
    static assert(structureTypeOf!VkApplicationInfo
        == VkStructureType.VK_STRUCTURE_TYPE_APPLICATION_INFO);
    static assert(structureTypeOf!VkSwapchainCreateInfoKHR
        == VkStructureType.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR);
    static assert(structureTypeOf!VkPresentInfoKHR
        == VkStructureType.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR);
    static assert(structureTypeOf!VkPhysicalDeviceFeatures2
        == VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2);
    static assert(structureTypeOf!VkPhysicalDeviceVulkan11Features
        == VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES);
    static assert(structureTypeOf!VkRenderingInfo
        == VkStructureType.VK_STRUCTURE_TYPE_RENDERING_INFO);
    static assert(structureTypeOf!VkPipelineRenderingCreateInfo
        == VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO);
    version (Windows)
        static assert(structureTypeOf!VkWin32SurfaceCreateInfoKHR
            == VkStructureType.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR);
    static assert(structureTypeOf!VkPhysicalDeviceDynamicRenderingFeatures
        == VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES);
    static assert(structureTypeOf!VkRenderingAttachmentInfo
        == VkStructureType.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO);
    static assert(structureTypeOf!VkImageMemoryBarrier
        == VkStructureType.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER);
}

@("vulkan.structure_type.irregularSpellings")
@safe pure nothrow @nogc unittest
{
    // Codec names, acronym pairs and digit-letter tokens that the digit-by-digit
    // transform splits where Vulkan does not.
    static assert(structureTypeOf!VkVideoDecodeH264ProfileInfoKHR
        == VkStructureType.VK_STRUCTURE_TYPE_VIDEO_DECODE_H264_PROFILE_INFO_KHR);
    static assert(structureTypeOf!VkVideoDecodeAV1CapabilitiesKHR
        == VkStructureType.VK_STRUCTURE_TYPE_VIDEO_DECODE_AV1_CAPABILITIES_KHR);
    static assert(structureTypeOf!VkPhysicalDeviceTextureCompressionASTCHDRFeatures
        == VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TEXTURE_COMPRESSION_ASTC_HDR_FEATURES);
    static assert(structureTypeOf!VkPhysicalDeviceYcbcr2Plane444FormatsFeaturesEXT
        == VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_YCBCR_2_PLANE_444_FORMATS_FEATURES_EXT);
    static assert(structureTypeOf!VkPhysicalDeviceShaderFloat16Int8Features
        == VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES);
}

@("vulkan.structure_type.matchingStructureType")
@safe pure nothrow unittest
{
    assert(matchingStructureType("VideoDecodeVP9ProfileInfoKHR")
        == "VK_STRUCTURE_TYPE_VIDEO_DECODE_VP9_PROFILE_INFO_KHR");
    assert(matchingStructureType("NoSuchStruct") == "");
}

@("vulkan.structure_type.vkInfoTagsTheStruct")
@safe pure nothrow @nogc unittest
{
    auto ci = vkInfo!VkInstanceCreateInfo();
    assert(ci.sType == VkStructureType.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO);

    // The other fields keep whatever the caller set; only the tag is imposed.
    auto sc = vkInfo(VkSwapchainCreateInfoKHR(minImageCount: 3));
    assert(sc.sType == VkStructureType.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR);
    assert(sc.minImageCount == 3);
}
