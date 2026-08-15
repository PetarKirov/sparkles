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

import sparkles.vulkan.vulkan_c;

/**
The `VK_STRUCTURE_TYPE_*` enumerator belonging to `T`.

Compile error if `T` is not a `Vk`-prefixed struct, or if the derived
enumerator does not exist.
*/
template structureTypeOf(T)
{
    static assert(is(T == struct), T.stringof ~ " is not a struct");
    static assert(T.stringof.length > 2 && T.stringof[0 .. 2] == "Vk",
        T.stringof ~ " is not a Vk* type");

    private enum name = "VK_STRUCTURE_TYPE_" ~ upperSnake(T.stringof[2 .. $]);

    static assert(__traits(hasMember, VkStructureType, name),
        "no `" ~ name ~ "` in VkStructureType (derived from " ~ T.stringof
            ~ "); the naming convention does not hold for this type");

    enum VkStructureType structureTypeOf = __traits(getMember, VkStructureType, name);
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
