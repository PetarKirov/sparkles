/**
The two-call enumeration pattern, once.

Vulkan returns variable-length results by making you call the same command
twice: once with a null output pointer to learn the count, then again with a
buffer of that size. Written out by hand it is five lines of ceremony per
query, and the interesting variation — some enumerators return `VkResult`,
others return `void` — is exactly the kind of difference that gets copy-pasted
wrong.

$(LREF queryVkList) collapses it, and picks the right shape at compile time by
asking what the command returns. It came out of
`libs/vulkan/examples/vulkaninfo.d`, which needed it seven times in one file;
`sparkles:ui-sdl3` needs it again for surface formats, present modes and
swapchain images, so it belongs here rather than in an example.
*/
module sparkles.vulkan.enumerate;

import sparkles.vulkan.c;
import sparkles.vulkan.result : isSuccess;

/**
Run a two-call Vulkan enumeration and return the result as a slice.

`fn` is the command; `args` are whatever precedes its `(count, items)` pair —
a physical device, an instance, a layer name. Both enumerator shapes are
handled: those returning `VkResult` and those returning `void`.

Returns `null` on failure or an empty result, which the callers of this pattern
treat identically — an empty list of present modes and a failed query both mean
"cannot present".

---
auto formats = queryVkList!VkSurfaceFormatKHR(
    inst.getPhysicalDeviceSurfaceFormatsKHR, gpu, surface);
---
*/
T[] queryVkList(T, Fn, Args...)(scope Fn fn, Args args) @system
{
    uint count;

    static if (is(typeof(fn(args, &count, null)) == void))
    {
        fn(args, &count, null);
        if (count == 0)
            return null;

        auto items = new T[count];
        fn(args, &count, items.ptr);
        return items;
    }
    else
    {
        if (!isSuccess(fn(args, &count, null)) || count == 0)
            return null;

        auto items = new T[count];
        if (!isSuccess(fn(args, &count, items.ptr)))
            return null;

        // A second call can report fewer items than the first (the set can
        // shrink between calls); trust the second count, not the buffer.
        return items[0 .. count];
    }
}

@("vulkan.enumerate.handlesBothEnumeratorShapes")
@system unittest
{
    // Neither shape can be exercised against a real driver in a unit test, so
    // the check is that both compile and that the void-returning shape is
    // distinguished from the VkResult one — the branch that would otherwise be
    // chosen by hand at each call site.
    static void voidShape(int tag, uint* count, float* items) @system
    {
        *count = 2;
        if (items !is null)
            items[0 .. 2] = [1.0f, 2.0f];
    }

    static VkResult resultShape(int tag, uint* count, float* items) @system
    {
        *count = 1;
        if (items !is null)
            items[0] = 42.0f;
        return VkResult.VK_SUCCESS;
    }

    assert(queryVkList!float(&voidShape, 0) == [1.0f, 2.0f]);
    assert(queryVkList!float(&resultShape, 0) == [42.0f]);
}

@("vulkan.enumerate.failureAndEmptyBothYieldNull")
@system unittest
{
    static VkResult fails(int tag, uint* count, float* items) @system
    {
        *count = 3;
        return VkResult.VK_ERROR_OUT_OF_HOST_MEMORY;
    }

    static VkResult empty(int tag, uint* count, float* items) @system
    {
        *count = 0;
        return VkResult.VK_SUCCESS;
    }

    assert(queryVkList!float(&fails, 0) is null);
    assert(queryVkList!float(&empty, 0) is null);
}

@("vulkan.enumerate.shrinkingSecondCallIsHonoured")
@system unittest
{
    // The count may shrink between the two calls. Returning the whole buffer
    // would hand the caller uninitialised elements.
    static uint calls;
    static VkResult shrinks(int tag, uint* count, float* items) @system
    {
        if (items is null)
        {
            *count = 4;
            return VkResult.VK_SUCCESS;
        }
        *count = 2;
        items[0 .. 2] = [7.0f, 8.0f];
        return VkResult.VK_SUCCESS;
    }

    assert(queryVkList!float(&shrinks, 0) == [7.0f, 8.0f]);
}
