/**
What a test needs to run Vulkan work on a real driver and fail on any message
the validation layer reports.

$(LREF HeadlessSession) opens a headless device with the Khronos validation
layer and a messenger counting the layer's warnings and errors; `close`
tears the device down while the messenger still listens, so an object left
alive is reported too. Such a test is opt-in through
`SPARKLES_VULKAN_READBACK=1` ($(LREF readbackEnabled)), since it needs a
driver — lavapipe in CI — and the layer; opted in, it fails rather than skips
when it cannot run.
*/
module sparkles.vulkan_wsi.testing;

import std.format : format;
import std.process : environment;

import sparkles.vulkan;
import sparkles.vulkan_wsi.device : ContextRequest, VulkanDevice;

/// Whether the environment opts in to tests on a real Vulkan driver.
bool readbackEnabled() @safe
    => environment.get("SPARKLES_VULKAN_READBACK", "") == "1";

/// Why a test that needs a driver did not run.
enum string readbackSkipReason = "a Vulkan readback is opt-in: SPARKLES_VULKAN_READBACK=1, "
    ~ "with a driver (lavapipe) and the validation layer";

/// What the validation layer reported: how many messages, and the start of
/// the first.
struct ValidationMessages
{
    uint count;          ///
    char[512] first = 0; ///
    size_t firstLength;  ///
}

// C linkage, so the name is global: qualified so it cannot collide.
private extern (C) VkBool32 sparklesVulkanWsiTestingOnMessage(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT types, VkDebugUtilsMessengerCallbackDataEXT* data,
    void* user) nothrow @nogc
{
    auto messages = cast(ValidationMessages*) user;
    if (messages.count++ == 0 && data !is null && data.pMessage !is null)
        for (auto p = data.pMessage; *p && messages.firstLength < messages.first.length; ++p)
            messages.first[messages.firstLength++] = *p;
    return VK_FALSE;
}

/**
A headless device with the validation layer, and a messenger counting the
layer's messages. Not copyable and address-pinned once open: the messenger
holds a pointer to `messages`.
*/
struct HeadlessSession
{
    VulkanDevice device;          ///
    ValidationMessages messages;  ///

    @disable this(this);

    /**
    Opens the device at `apiVersion`; asserts that it came up with the
    validation layer. The messenger is made as soon as the instance exists,
    so the layer's messages about choosing and creating the device count
    too; only those about creating the instance go to the console.
    */
    void open(string applicationName, uint apiVersion = apiVersion13) @system
    {
        auto info = vkInfo(VkDebugUtilsMessengerCreateInfoEXT(
            messageSeverity: VkDebugUtilsMessageSeverityFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
                | VkDebugUtilsMessageSeverityFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            messageType: VkDebugUtilsMessageTypeFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
            pfnUserCallback: &sparklesVulkanWsiTestingOnMessage,
            pUserData: &messages,
        ));
        auto made = VulkanDevice.createHeadless(device, ContextRequest(
            applicationName: applicationName, apiVersion: apiVersion, validation: true,
            messenger: &info));
        assert(!made.hasError, "SPARKLES_VULKAN_READBACK=1, but no headless Vulkan device: "
            ~ made.error.diagnostic[].idup);
        assert(device.validationEnabled && device.debugUtils,
            "SPARKLES_VULKAN_READBACK=1, but the validation layer did not load (VK_LAYER_PATH?)");
    }

    /**
    Destroys the device, the messenger still listening, and asserts the
    layer reported nothing. Release everything made on the device first.
    */
    void close() @system
    {
        device.releaseDevice();
        assert(messages.count == 0, format("the validation layer reported %s message(s), the first: %s",
            messages.count, messages.first[0 .. messages.firstLength]));
    }
}

/// Fails the test unless `r` is `VK_SUCCESS`. The call stays outside any
/// `assert`, which a build without assertions would delete with it.
void succeeded(VkResult r, string file = __FILE__, size_t line = __LINE__) @safe
{
    assert(r == VkResult.VK_SUCCESS, format("a Vulkan call at %s:%s failed: %s", file, line, r));
}
