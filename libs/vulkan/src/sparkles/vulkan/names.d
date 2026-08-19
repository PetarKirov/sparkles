/**
Enumerators, spelled for a human.

$(MREF sparkles,vulkan,structure_type) derives an enumerator from a type's name
at compile time. This is the other direction — a value's own name, with the
noise C forces on it taken off — and it is built the same way, so neither has a
table to keep in step with the headers.

The noise is twofold. C gives an enum no scope, so every member repeats the
type: `VK_PRESENT_MODE_FIFO_KHR`, not `Fifo`. And ImportC hands over the
promoted-extension aliases as real members sharing a value, which is why this
goes through `enumMemberNameOr` rather than
$(REF enumMemberName, sparkles,base,text,enums) — the latter cannot be
instantiated for `VkFormat` (57 duplicate-valued members) or `VkResult` (11) at
all.

$(B A vendor tag comes off only where the caller names it.) There is no table of
them here: a tag cannot be recognised structurally — `B8G8R8A8_UNORM` also ends
in an all-caps word — and a table would be one more thing to rot as vendors are
added. Each wrapper passes the tag its own enum carries instead, which is one
template argument at one site rather than a list to keep current.

$(B Word-shaped enumerators only.) `convertCase` splits at a digit/letter
boundary, so `VK_FORMAT_B8G8R8A8_UNORM` would render `b8-g8-r8-a8-unorm` — the
channel layout is one token to a reader, and mangling it helps nobody. There is
deliberately no `formatName`: a caller prints the enumerator, which is what the
spec and the validation layers call it.

$(B Not `resultName`.) $(MREF sparkles,vulkan,result) keeps its own hand-written
mapping because it renders the verbatim enumerator (`VK_ERROR_DEVICE_LOST`) for
a diagnostic a user may have to search the spec for, which is a different job
from the kebab-case display names here.
*/
module sparkles.vulkan.names;

import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.enums : enumCommonPrefix, enumMemberNameOr;

import sparkles.vulkan.vulkan_c;

/**
`value`'s member name in kebab-case, less the prefix its enum's members share.

`prefix` defaults to the derived $(REF enumCommonPrefix, sparkles,base,text,enums)
and is worth eyeballing once per enum: a legacy alias can drag it shorter than
the type name, which is why `VkColorSpaceKHR` passes one explicitly below.

`suffix` is the vendor tag this enum's members carry, where they carry one;
members without it are unaffected.

`fallback` covers a value that is not a declared member — a driver built against
a later spec than these headers, which is ordinary rather than a bug.
*/
string vkName(E, string prefix = enumCommonPrefix!E, string suffix = "")
    (E value, string fallback = "unknown") @safe pure nothrow @nogc
if (is(E == enum))
    => enumMemberNameOr!(CaseStyle.kebabCase, prefix, suffix)(value, fallback);

/// `VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU` → `"integrated-gpu"`.
string deviceTypeName(VkPhysicalDeviceType t) @safe pure nothrow @nogc
    => vkName(t, "other");

/// `VK_PRESENT_MODE_FIFO_RELAXED_KHR` → `"fifo-relaxed"`.
string presentModeName(VkPresentModeKHR m) @safe pure nothrow @nogc
    => vkName!(VkPresentModeKHR, enumCommonPrefix!VkPresentModeKHR, "_KHR")(m, "other");

/**
What choosing `m` costs, for a report that has room to say.

The name alone loses what the four modes actually differ on, which is the only
reason anyone reads a present-mode list. Mirrors the
`resultName`/`resultHint` pair in $(MREF sparkles,vulkan,result) rather than
inventing a second convention.
*/
string presentModeHint(VkPresentModeKHR m) @safe pure nothrow @nogc
{
    with (VkPresentModeKHR) switch (m)
    {
        case VK_PRESENT_MODE_IMMEDIATE_KHR:    return "no vsync, tears";
        case VK_PRESENT_MODE_MAILBOX_KHR:      return "vsync, no tear, drops frames";
        case VK_PRESENT_MODE_FIFO_KHR:         return "vsync, always available";
        case VK_PRESENT_MODE_FIFO_RELAXED_KHR: return "vsync, tears when late";
        default:                               return null;
    }
}


@("vulkan.names.rendersTheDisplayVocabulary")
@safe pure nothrow @nogc unittest
{
    // The exact strings `libs/ui-sdl3/examples/vulkan-window.d` and the
    // `DeviceType` wire enum in `libs/vulkan/examples/vulkaninfo.d` each spelled
    // out by hand, in three places, before this module existed.
    with (VkPhysicalDeviceType)
    {
        assert(deviceTypeName(VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) == "integrated-gpu");
        assert(deviceTypeName(VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) == "discrete-gpu");
        assert(deviceTypeName(VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU) == "virtual-gpu");
        assert(deviceTypeName(VK_PHYSICAL_DEVICE_TYPE_CPU) == "cpu");
        assert(deviceTypeName(VK_PHYSICAL_DEVICE_TYPE_OTHER) == "other");
    }

}

@("vulkan.names.survivesTheEnumsImportCCannotSwitchOn")
@safe pure nothrow @nogc unittest
{
    // The reason this module exists. `VkFormat` and `VkColorSpaceKHR` carry
    // duplicate-valued alias members, so the `final switch` form cannot be
    // instantiated for them — a compile error, not a wrong answer.
    import sparkles.base.text.enums : enumMemberName;

    static assert(!__traits(compiles, enumMemberName(VkFormat.init)));
    static assert(!__traits(compiles, enumMemberName(VkColorSpaceKHR.init)));
    static assert(__traits(compiles, vkName(VkFormat.init)));

    // First declaration wins, so a promoted enumerator renders as its core
    // spelling rather than whichever alias the compiler happened to reach.
    assert(presentModeName(VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR) == "mailbox");
}

@("vulkan.names.kebabCaseIsWrongForDigitBearingIdentifiers")
@safe pure nothrow @nogc unittest
{
    // Why there is no `formatName`. `convertCase` splits a word at a
    // digit/letter boundary, which is right for `fastPath2` and wrong for a
    // Vulkan format: the channel layout is one token to anyone reading it.
    assert(vkName(VkFormat.VK_FORMAT_B8G8R8A8_UNORM) == "b8-g8-r8-a8-unorm");

    // So formats stay unrendered, and a caller who wants one prints the
    // enumerator itself — `VK_FORMAT_B8G8R8A8_UNORM` is the spelling the spec,
    // the validation layers and every other tool use.
}

@("vulkan.names.unknownValueFallsBackRatherThanAsserting")
@safe pure nothrow @nogc unittest
{
    // A driver built against a later spec reports enumerators these headers do
    // not declare. That is ordinary, and it must not take the process down.
    assert(deviceTypeName(cast(VkPhysicalDeviceType) 9999) == "other");
    assert(presentModeName(cast(VkPresentModeKHR) 9999) == "other");
    assert(vkName(cast(VkFormat) 999_999) == "unknown");
}

@("vulkan.names.presentModeHintExplainsTheTradeoff")
@safe pure nothrow @nogc unittest
{
    with (VkPresentModeKHR)
    {
        assert(presentModeName(VK_PRESENT_MODE_FIFO_RELAXED_KHR) == "fifo-relaxed");
        assert(presentModeName(VK_PRESENT_MODE_IMMEDIATE_KHR) == "immediate");
        assert(presentModeName(VK_PRESENT_MODE_MAILBOX_KHR) == "mailbox");
        assert(presentModeName(VK_PRESENT_MODE_FIFO_KHR) == "fifo");
        assert(presentModeHint(VK_PRESENT_MODE_FIFO_KHR) == "vsync, always available");
        // A mode with nothing to add says nothing, like `resultHint`.
        assert(presentModeHint(cast(VkPresentModeKHR) 9999) is null);
    }
}
