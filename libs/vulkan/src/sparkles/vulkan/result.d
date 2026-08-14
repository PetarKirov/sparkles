/**
`VkResult` as an $(REF Expected, expected).

Vulkan returns a status code from nearly every entry point, and C leaves it to
the caller to remember which ones matter. A bare `VkResult` is easy to drop —
and dropping it is how a lost device or an out-of-date swapchain turns into a
crash three frames later instead of a handled condition.

`Expected!(T, VkResult)` puts the failure in the type, matching the repo's
error-handling idiom
($(LINK2 ../../../docs/guidelines/idioms/expected/index.md, Expected Error Handling)),
and stays `@nogc nothrow` so the frame loop can use it.

Note that not every non-`VK_SUCCESS` code is a failure: `VK_SUBOPTIMAL_KHR`
means the frame was presented and the swapchain should be rebuilt soon, and
`VK_TIMEOUT` is the normal answer to a zero-timeout wait. $(LREF isSuccess)
follows Vulkan's own rule — negative codes are errors, non-negative are not —
so the caller decides what a warning means rather than the binding guessing.
*/
module sparkles.vulkan.result;

import expected : Expected, err, ok;

import sparkles.vulkan.c;

/// An operation that either produced a `T` or failed with a `VkResult`.
alias VkExpected(T = void) = Expected!(T, VkResult);

/**
Vulkan's own success rule: negative codes are errors, everything else is not.

`VK_SUCCESS` is 0, warnings such as `VK_SUBOPTIMAL_KHR` and `VK_TIMEOUT` are
positive, and every error is negative. Testing `== VK_SUCCESS` instead would
turn a presented-but-suboptimal frame into a failure.
*/
bool isSuccess(VkResult r) @safe pure nothrow @nogc => r >= 0;

/// `true` only for `VK_SUCCESS` — for the calls where a warning is not good enough.
bool isExactSuccess(VkResult r) @safe pure nothrow @nogc
    => r == VkResult.VK_SUCCESS;

/**
Lift a `VkResult` into an $(LREF VkExpected), keeping the code on failure.

Non-negative codes succeed, so a `VK_SUBOPTIMAL_KHR` present is a success whose
code the caller can still inspect via $(LREF checked).
*/
VkExpected!() check(VkResult r) @safe pure nothrow @nogc
    => isSuccess(r) ? ok!VkResult() : err!void(r);

/// ditto, carrying `value` through on success.
VkExpected!T check(T)(VkResult r, T value)
    => isSuccess(r) ? ok!VkResult(value) : err!T(r);

/// The `VkResult` itself on success, so warnings survive the lift.
VkExpected!VkResult checked(VkResult r) @safe pure nothrow @nogc
    => isSuccess(r) ? ok!VkResult(r) : err!VkResult(r);

/**
The enumerator's spelling, for diagnostics.

Covers the codes a window-system and swapchain path can actually see; anything
else renders as `VK_ERROR_<unknown>` rather than growing a 90-arm switch that
nothing exercises. Returns a string literal, so it is `@nogc`.
*/
string resultName(VkResult r) @safe pure nothrow @nogc
{
    with (VkResult) switch (r)
    {
        case VK_SUCCESS:                        return "VK_SUCCESS";
        case VK_NOT_READY:                      return "VK_NOT_READY";
        case VK_TIMEOUT:                        return "VK_TIMEOUT";
        case VK_EVENT_SET:                      return "VK_EVENT_SET";
        case VK_EVENT_RESET:                    return "VK_EVENT_RESET";
        case VK_INCOMPLETE:                     return "VK_INCOMPLETE";
        case VK_SUBOPTIMAL_KHR:                 return "VK_SUBOPTIMAL_KHR";
        case VK_ERROR_OUT_OF_HOST_MEMORY:       return "VK_ERROR_OUT_OF_HOST_MEMORY";
        case VK_ERROR_OUT_OF_DEVICE_MEMORY:     return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
        case VK_ERROR_INITIALIZATION_FAILED:    return "VK_ERROR_INITIALIZATION_FAILED";
        case VK_ERROR_DEVICE_LOST:              return "VK_ERROR_DEVICE_LOST";
        case VK_ERROR_MEMORY_MAP_FAILED:        return "VK_ERROR_MEMORY_MAP_FAILED";
        case VK_ERROR_LAYER_NOT_PRESENT:        return "VK_ERROR_LAYER_NOT_PRESENT";
        case VK_ERROR_EXTENSION_NOT_PRESENT:    return "VK_ERROR_EXTENSION_NOT_PRESENT";
        case VK_ERROR_FEATURE_NOT_PRESENT:      return "VK_ERROR_FEATURE_NOT_PRESENT";
        case VK_ERROR_INCOMPATIBLE_DRIVER:      return "VK_ERROR_INCOMPATIBLE_DRIVER";
        case VK_ERROR_TOO_MANY_OBJECTS:         return "VK_ERROR_TOO_MANY_OBJECTS";
        case VK_ERROR_FORMAT_NOT_SUPPORTED:     return "VK_ERROR_FORMAT_NOT_SUPPORTED";
        case VK_ERROR_SURFACE_LOST_KHR:         return "VK_ERROR_SURFACE_LOST_KHR";
        case VK_ERROR_NATIVE_WINDOW_IN_USE_KHR: return "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR";
        case VK_ERROR_OUT_OF_DATE_KHR:          return "VK_ERROR_OUT_OF_DATE_KHR";
        case VK_ERROR_INCOMPATIBLE_DISPLAY_KHR: return "VK_ERROR_INCOMPATIBLE_DISPLAY_KHR";
        case VK_ERROR_VALIDATION_FAILED_EXT:    return "VK_ERROR_VALIDATION_FAILED_EXT";
        case VK_ERROR_UNKNOWN:                  return "VK_ERROR_UNKNOWN";
        default:                                return "VK_ERROR_<unknown>";
    }
}

@("vulkan.result.successRuleFollowsVulkan")
@safe pure nothrow @nogc unittest
{
    with (VkResult)
    {
        assert(isSuccess(VK_SUCCESS));
        // Warnings are successes: the frame WAS presented.
        assert(isSuccess(VK_SUBOPTIMAL_KHR));
        assert(isSuccess(VK_TIMEOUT));
        assert(!isSuccess(VK_ERROR_OUT_OF_DATE_KHR));
        assert(!isSuccess(VK_ERROR_DEVICE_LOST));

        // ... but the strict form exists for the calls that need it.
        assert(isExactSuccess(VK_SUCCESS));
        assert(!isExactSuccess(VK_SUBOPTIMAL_KHR));
    }
}

// Not `pure`: reading `.error` goes through the `Abort` hook's
// `onAccessEmptyError`, which is impure by construction.
@("vulkan.result.checkLiftsIntoExpected")
@safe nothrow @nogc unittest
{
    with (VkResult)
    {
        // `Expected!(void, E)` carries no value, so success is the absence of
        // an error rather than the presence of one.
        assert(!check(VK_SUCCESS).hasError);
        assert(check(VK_ERROR_DEVICE_LOST).hasError);
        assert(check(VK_ERROR_DEVICE_LOST).error == VK_ERROR_DEVICE_LOST);

        // A carried value survives success and is absent on failure.
        auto okv = check(VK_SUCCESS, 42);
        assert(okv.hasValue && okv.value == 42);
        assert(check(VK_ERROR_OUT_OF_DATE_KHR, 42).hasError);

        // `checked` keeps the warning code, which `check` discards.
        auto sub = checked(VK_SUBOPTIMAL_KHR);
        assert(sub.hasValue && sub.value == VK_SUBOPTIMAL_KHR);
    }
}

@("vulkan.result.resultNameCoversTheSwapchainCodes")
@safe pure nothrow @nogc unittest
{
    with (VkResult)
    {
        assert(resultName(VK_SUCCESS) == "VK_SUCCESS");
        assert(resultName(VK_ERROR_OUT_OF_DATE_KHR) == "VK_ERROR_OUT_OF_DATE_KHR");
        assert(resultName(VK_SUBOPTIMAL_KHR) == "VK_SUBOPTIMAL_KHR");
        assert(resultName(cast(VkResult) -424242) == "VK_ERROR_<unknown>");
    }
}
