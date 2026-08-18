/**
Extension lists, and the one handshake that depends on reading them.

$(B The portability handshake.) MoltenVK is not a normal ICD: the
Khronos loader hides it unless the instance enables
$(LREF khrPortabilityEnumeration) $(I and) sets
$(LREF portabilityEnumerationFlag), and a device created on it must enable
$(LREF khrPortabilitySubset). Miss any of the three and the symptom is not an
error — it is an empty `vkEnumeratePhysicalDevices`, or a validation failure
several calls later. Enabling them unconditionally is equally wrong: a regular
desktop ICD does not advertise the extension, and asking for it fails instance
creation outright.

So the decision is "ask the loader, then do what it says", and it is the same
decision in every consumer — `sparkles:ui-sdl3` bringing up a window, and
`libs/vulkan/examples/vulkaninfo.d` enumerating from a bare loader. It lives
here so those two cannot drift apart, which they had already begun to do.
*/
module sparkles.vulkan.extensions;

import sparkles.vulkan.dispatch : GlobalCommands, InstanceCommands, matchesHeaderMacro;
import sparkles.vulkan.enumerate : queryVkList;
import sparkles.vulkan.vulkan_c;

/// Instance extension that opts into enumerating portability ICDs (MoltenVK).
enum string khrPortabilityEnumeration = "VK_KHR_portability_enumeration";
/// Device extension a portability ICD advertises and requires enabled.
enum string khrPortabilitySubset = "VK_KHR_portability_subset";

/**
`VkInstanceCreateInfo.flags` bit that must accompany
$(LREF khrPortabilityEnumeration).

Without both the extension and this bit, the Khronos loader hides MoltenVK and
`vkEnumeratePhysicalDevices` returns an empty list on Darwin.
*/
enum VkInstanceCreateFlags portabilityEnumerationFlag =
    VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;

/**
`true` when `advertised` contains `name`.

Note `p.extensionName.fromStringz` and not `p.extensionName.ptr.fromStringz`.
The name is a fixed 256-byte array, and the two spellings pick different
overloads: the array one is `@safe pure nothrow @nogc` and stops at the array's
end, while taking `.ptr` first selects the `@system` pointer overload, which
reads past the field if a driver ever fails to terminate the name.
*/
bool hasExtension(scope const VkExtensionProperties[] advertised, scope const(char)[] name)
    @safe pure nothrow @nogc
{
    import std.string : fromStringz;

    foreach (ref p; advertised)
        if (p.extensionName.fromStringz == name)
            return true;
    return false;
}

/**
What a portability ICD requires of `VkInstanceCreateInfo`, if anything.

`available` is the loader's answer, not the platform's: a Darwin host with the
Khronos loader and MoltenVK installed advertises the extension, and a Linux
host with a normal ICD does not. Everything else follows from it.
*/
struct InstancePortability
{
    /// The loader advertises $(LREF khrPortabilityEnumeration).
    bool available;

    /**
    ... and the caller's own extension list does not already name it.

    SDL's `SDL_Vulkan_GetInstanceExtensions` does not include it today, but a
    future SDL that does must not make the list name it twice — duplicate
    extension names are a `VK_ERROR_EXTENSION_NOT_PRESENT` on some loaders.
    */
    bool addExtension;

    /// The create flag to pass, which is meaningful only when the extension is enabled.
    VkInstanceCreateFlags flags() const @safe pure nothrow @nogc
        => available ? portabilityEnumerationFlag : 0;
}

/**
Decide the instance-side handshake from an already-queried extension list.

`requested` is what the caller already intends to enable — SDL's surface
extensions, typically — so the answer accounts for a list that already names
the portability extension. Pass `null` when enabling nothing else.
*/
InstancePortability instancePortability(scope const VkExtensionProperties[] advertised,
    scope const(char*)[] requested) @system pure nothrow @nogc
{
    import std.string : fromStringz;

    InstancePortability r;
    r.available = advertised.hasExtension(khrPortabilityEnumeration);
    if (!r.available)
        return r;

    r.addExtension = true;
    foreach (name; requested)
        if (name !is null && name.fromStringz == khrPortabilityEnumeration)
        {
            r.addExtension = false;
            break;
        }
    return r;
}

/// ditto, querying the loader for the list.
InstancePortability instancePortability(in GlobalCommands g, scope const(char*)[] requested)
    @system nothrow
in (g.enumerateInstanceExtensionProperties !is null, "global tier is not loaded")
    => instancePortability(
        queryVkList!VkExtensionProperties(g.enumerateInstanceExtensionProperties, null),
        requested);

/**
`true` when `gpu` is a portability device, so `VK_KHR_portability_subset` must
be enabled on the logical device.

`VUID-VkDeviceCreateInfo-pProperties-04451` makes this mandatory rather than
optional: a physical device that advertises the extension and a `vkCreateDevice`
that omits it is a validation error, not a fallback.
*/
bool needsPortabilitySubset(in InstanceCommands inst, VkPhysicalDevice gpu) @system nothrow
in (inst.enumerateDeviceExtensionProperties !is null, "instance tier is not loaded")
    => queryVkList!VkExtensionProperties(
        inst.enumerateDeviceExtensionProperties, gpu, null)
        .hasExtension(khrPortabilitySubset);

version (unittest)
{
    /// One advertised extension, zero-filled — `char.init` is `0xFF`, not NUL.
    private VkExtensionProperties advertise(string name) @safe pure nothrow @nogc
    {
        VkExtensionProperties p;
        p.extensionName[] = '\0';
        p.extensionName[0 .. name.length] = name;
        return p;
    }
}

@("vulkan.extensions.nameReadsStayInsideTheArray")
@safe pure nothrow @nogc unittest
{
    // A regression guard, not a test of Phobos: the array overload of
    // `fromStringz` is what keeps this `@safe`, and someone "tidying" it back
    // to `.ptr.fromStringz` would silently reintroduce a read past the field.
    import std.string : fromStringz;

    assert(advertise("VK_KHR_swapchain").extensionName.fromStringz == "VK_KHR_swapchain");
    assert(advertise("").extensionName.fromStringz == "");

    // The field itself is the padded array, so a comparison against it fails.
    assert(advertise("VK_KHR_swapchain").extensionName.length == VK_MAX_EXTENSION_NAME_SIZE);

    // The case the pointer overload gets wrong: a driver that fills all 256
    // bytes without terminating. Stopping at the bound is the only safe answer.
    VkExtensionProperties unterminated;
    unterminated.extensionName[] = 'x';
    assert(unterminated.extensionName.fromStringz.length
        == unterminated.extensionName.length);
}

@("vulkan.extensions.hasExtensionMatchesWholeNames")
@safe pure nothrow @nogc unittest
{
    const VkExtensionProperties[2] advertised =
        [advertise("VK_KHR_surface"), advertise(khrPortabilityEnumeration)];
    assert(advertised[].hasExtension(khrPortabilityEnumeration));
    assert(advertised[].hasExtension("VK_KHR_surface"));

    // A prefix is not a match — the padding must not make one name look like another.
    assert(!advertised[].hasExtension("VK_KHR_surf"));
    assert(!advertised[].hasExtension("VK_KHR_swapchain"));
    assert(!(cast(VkExtensionProperties[]) null).hasExtension("VK_KHR_surface"));
}

// `@system`: `requested` is a list of raw C strings, as SDL hands them over.
@("vulkan.extensions.portabilityFollowsTheLoaderNotThePlatform")
@system pure nothrow @nogc unittest
{
    // A regular desktop ICD: the extension is absent, so asking for it would
    // fail instance creation. Nothing to do, and no flag.
    const VkExtensionProperties[1] plain = [advertise("VK_KHR_surface")];
    const none = instancePortability(plain[], null);
    assert(!none.available && !none.addExtension);
    assert(none.flags == 0);

    // A loader that can see MoltenVK: both halves of the handshake.
    const VkExtensionProperties[2] portable =
        [advertise("VK_KHR_surface"), advertise(khrPortabilityEnumeration)];
    const add = instancePortability(portable[], null);
    assert(add.available && add.addExtension);
    assert(add.flags == portabilityEnumerationFlag);

    // ... but if the caller's list already names it, the flag still has to be
    // set while the name must not be added twice.
    const(char*)[1] already = [khrPortabilityEnumeration.ptr];
    const dedup = instancePortability(portable[], already[]);
    assert(dedup.available && !dedup.addExtension);
    assert(dedup.flags == portabilityEnumerationFlag);

    // An unrelated request is not mistaken for the portability one.
    const(char*)[1] other = ["VK_KHR_surface".ptr];
    assert(instancePortability(portable[], other[]).addExtension);
}

@("vulkan.extensions.portabilityNamesArePinnedToTheHeader")
@safe pure nothrow @nogc unittest
{
    // Pinned to the header's macro, not to a second copy of the literal, so a
    // typo is a compile error instead of an extension that never matches.
    static assert(matchesHeaderMacro(khrPortabilityEnumeration,
        VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME));

    // `khrPortabilitySubset` has no counterpart to pin against: its macro
    // lives in `vulkan_beta.h`, behind `VK_ENABLE_BETA_EXTENSIONS`, which
    // `c.c` does not define. The name is spelled out here by necessity.
    static assert(khrPortabilitySubset == "VK_KHR_portability_subset");
}
