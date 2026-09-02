/** Typed failures at the native-window/Vulkan boundary. */
module sparkles.vulkan_wsi.error;

import expected : Expected, err, ok;

import sparkles.vulkan : VkResult;
import sparkles.base.buffer : InlineBuffer;
import sparkles.wsi : BackendKind;

@safe:

enum VulkanWsiErrorKind : ubyte
{
    unsupported,
    mismatchedHandles,
    loaderUnavailable,
    missingExtension,
    incompleteDispatch,
    noPresentDevice,
    vulkanFailure,
}

enum VulkanWsiOperation : ubyte
{
    none,
    planSurface,
    load,
    createInstance,
    createSurface,
    selectDevice,
    createDevice,
}

struct VulkanWsiError
{
    VulkanWsiErrorKind kind;
    VulkanWsiOperation operation;
    BackendKind backend;
    VkResult vkResult;
    InlineBuffer!(char, 128) diagnostic;
}

struct VulkanWsiExpectedHook
{
    static immutable bool enableDefaultConstructor = false;

    static void onAccessEmptyValue(E)(E error) pure nothrow @nogc
        => assert(false, "accessed the value of an error VulkanWsiResult");
}

alias VulkanWsiResult(T = void) =
    Expected!(T, VulkanWsiError, VulkanWsiExpectedHook);

/**
Resource-management failures after context bring-up.

This aliases the existing SDL presentation error shape during extraction, so
`sparkles:ui-sdl3` can consume the shared command/frame/swapchain types without
an error conversion layer. Context and native-surface failures remain the
structured $(LREF VulkanWsiError) above.
*/
alias PresentationResult(T = void) = Expected!(T, string);

VulkanWsiResult!T vulkanWsiOk(T)(auto ref T value)
{
    import core.lifetime : forward;

    return ok!(VulkanWsiError, VulkanWsiExpectedHook)(forward!value);
}

VulkanWsiResult!void vulkanWsiOk() pure nothrow @nogc
    => ok!(VulkanWsiError, VulkanWsiExpectedHook)();

VulkanWsiResult!T vulkanWsiErr(T)(VulkanWsiError error) pure nothrow @nogc
    => err!(T, VulkanWsiExpectedHook)(error);

VulkanWsiError vulkanWsiError(VulkanWsiErrorKind kind,
    VulkanWsiOperation operation, BackendKind backend,
    VkResult result = VkResult.VK_SUCCESS,
    scope const(char)[] diagnostic = null) pure nothrow @nogc
{
    VulkanWsiError error = VulkanWsiError(kind, operation, backend, result);
    if (!error.diagnostic.assign(diagnostic))
    {
        // The fallback text fits the inline capacity by construction.
        const assigned =
            error.diagnostic.assign("diagnostic exceeds inline capacity");
        assert(assigned);
    }
    return error;
}
