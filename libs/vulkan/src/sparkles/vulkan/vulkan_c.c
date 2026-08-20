// The ImportC surface: the real `vulkan.h`, compiled by the D compiler, so
// struct layout, enum values and function-pointer signatures cannot drift from
// the headers `flake.lock` pins.
//
// `VK_NO_PROTOTYPES` is the load-bearing define. Without it the header declares
// ~400 `vkFoo` prototypes and the binding would resolve them against whatever
// `libvulkan.so` the linker found — a single process-global implementation
// chosen at link time. With it, the header declares only the `PFN_vk*`
// typedefs, and every call goes through a pointer this library loads
// explicitly. That is what makes the three dispatch tiers in `dispatch.d`
// possible, and it is why a second device (Skia's) can coexist with ours
// instead of overwriting a shared table — the failure mode ErupteD documents
// for its own `__gshared` command pointers.
//
// Platform surface declarations are part of the binding, while creation policy
// lives in `sparkles:vulkan-wsi`. SDL consumers may still obtain a surface from
// SDL, but native WSI must use the same VkInstance/VkSurfaceKHR vocabulary
// without maintaining a second hand-written ABI. Only declarations for the
// target platform are exposed, so foreign platform SDK headers never leak into
// a cross-compile.
#define VK_NO_PROTOTYPES

#if defined(__linux__)
#define VK_USE_PLATFORM_WAYLAND_KHR
#define VK_USE_PLATFORM_XCB_KHR
#endif

// `nothrow @nogc` is accurate for the whole surface: these are C entry points
// reached through function pointers; they neither allocate via the D GC nor
// throw D exceptions. `pure` is deliberately omitted — Vulkan calls mutate
// device and driver state. See https://dlang.org/spec/importc#pragma.
#pragma attribute(push, nogc, nothrow)
#include <vulkan/vulkan.h>
#pragma attribute(pop)
