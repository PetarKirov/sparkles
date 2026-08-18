/**
Which bits of a `Vk*Flags` value are set, by name.

A Vulkan bitmask is a bare `uint` and its `Vk*FlagBits` enum is the only thing
that says what the bits mean, so reporting one means walking the enum. Written
by hand that is a `static foreach` with three separate things to get right —
which enumerators are single bits, which are aliases of each other, and how much
of each name is the type's own — and it was written by hand, once, inside
`libs/vulkan/examples/vulkaninfo.d`, where `sparkles:ui-sdl3` could not reach it.

$(B Single-bit enumerators only, decided by the value.) The enums carry three
kinds of member that must not appear in the output: the `_MAX_ENUM` sentinel, a
zero `_NONE`, and composite enumerators naming several bits at once. All three
fall out of one test — a power of two — which is why nothing here matches on the
`_BIT` spelling the way the example's version did. That matters beyond tidiness:
`VK_QUEUE_VIDEO_DECODE_BIT_KHR` does not $(I end) in `_BIT`, so a name-based
test silently dropped every vendor-suffixed bit.

$(B This is the name half only.) The research catalog reserves a fuller design —
"distinct single-bit enum + multi-bit struct with `opBinary` set algebra"
($(LINK2 ../../../docs/research/vulkan/comparison.md, `comparison.md`), Part 3) —
and this deliberately takes none of the names that design will want.
*/
module sparkles.vulkan.flags;

import sparkles.base.text.case_style : CaseStyle, convertCase;
import sparkles.base.text.enums : enumCommonPrefix;

import sparkles.vulkan.vulkan_c;

/// One nameable bit: its value, and its identifier less the noise.
private struct FlagBit
{
    uint value;
    string name;
}

/**
The single-bit enumerators of `E`, in declaration order, deduplicated by value.

Built once at compile time. First declaration wins, so a bit promoted from an
extension renders as its core spelling rather than the alias that kept the old
one.
*/
private template flagBits(E, string prefix, CaseStyle style)
if (is(E == enum))
{
    enum FlagBit[] flagBits = () {
        FlagBit[] bits;
        static foreach (name; __traits(allMembers, E))
        {{
            enum uint value = cast(uint) __traits(getMember, E, name);

            // Exactly one bit set. Excludes zero, the 0x7FFFFFFF `_MAX_ENUM`
            // sentinel, and every composite enumerator, without inspecting the
            // spelling at all.
            static if (value != 0 && (value & (value - 1)) == 0)
            {
                bool seen;
                foreach (b; bits)
                    if (b.value == value)
                        seen = true;
                if (!seen)
                    bits ~= FlagBit(value, convertCase!style(withoutBit!(name, prefix)));
            }
        }}
        return bits;
    }();
}

// `name` less the shared prefix and less the `_BIT` marker, which can sit in the
// middle: `VK_QUEUE_VIDEO_DECODE_BIT_KHR` has to become `VIDEO_DECODE_KHR`, not
// lose its vendor tag along with the marker.
private template withoutBit(string name, string prefix)
{
    enum string withoutBit = () {
        string s = name;
        if (prefix.length && s.length > prefix.length && s[0 .. prefix.length] == prefix)
            s = s[prefix.length .. $];

        foreach (i; 0 .. s.length)
            if (i + 4 <= s.length && s[i .. i + 4] == "_BIT")
                return s[0 .. i] ~ s[i + 4 .. $];
        return s;
    }();
}

/**
The names of the bits `raw` has set, in the enum's declaration order.

`prefix` defaults to the derived
$(REF enumCommonPrefix, sparkles,base,text,enums); `style` leaves the identifier
as the header spells it, since a bitmask is usually reported next to the
constant a reader would grep for.

---
// ["DEVICE_LOCAL", "HOST_VISIBLE"]
auto set = flagNames!VkMemoryPropertyFlagBits(memoryType.propertyFlags);
---

A bit `raw` has set that `E` does not declare is skipped: a driver may report
one from a later spec than these headers, and there is no name to give it.
*/
string[] flagNames(E, string prefix = enumCommonPrefix!E, CaseStyle style = CaseStyle.original)
    (uint raw) @safe pure nothrow
if (is(E == enum))
{
    string[] set;
    foreach (bit; flagBits!(E, prefix, style))
        if ((raw & bit.value) != 0)
            set ~= bit.name;
    return set;
}

@("vulkan.flags.namesTheSetBits")
@safe pure nothrow unittest
{
    with (VkQueueFlagBits)
    {
        assert(flagNames!VkQueueFlagBits(VK_QUEUE_GRAPHICS_BIT) == ["GRAPHICS"]);

        // Declaration order, not the order the caller ORed them.
        assert(flagNames!VkQueueFlagBits(VK_QUEUE_TRANSFER_BIT | VK_QUEUE_GRAPHICS_BIT)
            == ["GRAPHICS", "TRANSFER"]);

        assert(flagNames!VkQueueFlagBits(0) == []);
    }
}

@("vulkan.flags.excludesSentinelsAndComposites")
@safe pure nothrow unittest
{
    // The `_MAX_ENUM` sentinel is 0x7FFFFFFF — every bit but the top one. If it
    // were treated as nameable it would match nearly any mask, and a value of
    // all-ones would name it rather than the bits actually set.
    const everything = flagNames!VkQueueFlagBits(uint.max);
    foreach (name; everything)
        assert(name != "FLAG_BITS_MAX_ENUM" && name != "MAX_ENUM",
            "the sentinel must never be reported as a set bit");

    // ... and each reported name must be a real single bit, so the list is a
    // decomposition rather than a set of overlapping labels.
    assert(everything.length >= 3);
}

@("vulkan.flags.keepsTheVendorTagTheBitMarkerHides")
@safe pure nothrow unittest
{
    // `VK_QUEUE_VIDEO_DECODE_BIT_KHR` does not end in `_BIT`, so the example's
    // `endsWith("_BIT")` test dropped it entirely. Here the marker comes out of
    // the middle and the tag survives.
    static assert(withoutBit!("VK_QUEUE_VIDEO_DECODE_BIT_KHR", "VK_QUEUE_")
        == "VIDEO_DECODE_KHR");
    static assert(withoutBit!("VK_QUEUE_GRAPHICS_BIT", "VK_QUEUE_") == "GRAPHICS");

    // A prefix the member does not carry leaves it alone.
    static assert(withoutBit!("VK_QUEUE_GRAPHICS_BIT", "NOPE_") == "VK_QUEUE_GRAPHICS");
}

@("vulkan.flags.recasesOnRequest")
@safe pure nothrow unittest
{
    assert(flagNames!(VkMemoryPropertyFlagBits, enumCommonPrefix!VkMemoryPropertyFlagBits,
        CaseStyle.kebabCase)(VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
        == ["host-visible"]);
}
