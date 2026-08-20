/** Minimal target surface declarations not safely ImportC-able from an SDK. */
module sparkles.vulkan.platform;

public import sparkles.vulkan.vulkan_c;

version (Windows)
{
    /**
    The Win32 Vulkan surface ABI without importing `windows.h` into ImportC.

    The MSVC SDK defines hundreds of inline functions containing compiler
    intrinsics. ImportC correctly emits those bodies, but LLD then sees unused
    references such as `_InterlockedExchangeAdd`. Vulkan's surface ABI needs
    only two opaque Win32 handles, so spell that stable header fragment here.
    */
    alias VkWin32SurfaceCreateFlagsKHR = VkFlags;

    struct VkWin32SurfaceCreateInfoKHR
    {
        VkStructureType sType;
        const(void)* pNext;
        VkWin32SurfaceCreateFlagsKHR flags;
        void* hinstance;
        void* hwnd;
    }

    alias PFN_vkCreateWin32SurfaceKHR = extern (Windows) VkResult function(
        VkInstance instance, const(VkWin32SurfaceCreateInfoKHR)* createInfo,
        const(VkAllocationCallbacks)* allocator, VkSurfaceKHR* surface)
        nothrow @nogc;
    alias PFN_vkGetPhysicalDeviceWin32PresentationSupportKHR =
        extern (Windows) VkBool32 function(VkPhysicalDevice physicalDevice,
            uint queueFamilyIndex) nothrow @nogc;
}
else version (OSX)
{
    // `CAMetalLayer` is opaque in vulkan_metal.h for a non-Objective-C client.
    alias VkMetalSurfaceCreateFlagsEXT = VkFlags;

    struct VkMetalSurfaceCreateInfoEXT
    {
        VkStructureType sType;
        const(void)* pNext;
        VkMetalSurfaceCreateFlagsEXT flags;
        const(void)* pLayer;
    }

    alias PFN_vkCreateMetalSurfaceEXT = extern (C) VkResult function(
        VkInstance instance, const(VkMetalSurfaceCreateInfoEXT)* createInfo,
        const(VkAllocationCallbacks)* allocator, VkSurfaceKHR* surface)
        nothrow @nogc;
}
