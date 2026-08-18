/**
Vulkan for D: the real headers through ImportC, with the ergonomics the C API
leaves to the caller.

The pieces, each answering something the raw header does not:

$(UL
$(LI $(MREF sparkles,vulkan,c) — `vulkan.h` compiled by the D compiler under
    `VK_NO_PROTOTYPES`, so layouts and enum values cannot drift from the pinned
    headers and every entry point is a function pointer rather than a linked
    symbol.)
$(LI $(MREF sparkles,vulkan,loader) — `vkGetInstanceProcAddr` from the
    platform loader (`libvulkan.so.1` / `libvulkan.1.dylib` / MoltenVK),
    so a caller that is not going through SDL does not have to hard-code
    a soname.)
$(LI $(MREF sparkles,vulkan,dispatch) — the global/instance/device tiers, each
    table paired with the handle it was resolved from, so a second device
    cannot overwrite the first.)
$(LI $(MREF sparkles,vulkan,structure_type) — `sType` derived from the struct's
    own name at compile time, so a mistagged create-info is a compile error.)
$(LI $(MREF sparkles,vulkan,enumerate) — Vulkan's two-call
    count-then-fill enumeration pattern, written once and specialised at
    compile time on whether the command returns `VkResult` or `void`.)
$(LI $(MREF sparkles,vulkan,extensions) — extension names read inside their
    fixed-array bound, and the portability handshake MoltenVK needs, decided
    once instead of at each consumer.)
$(LI $(MREF sparkles,vulkan,result) — `VkResult` as
    `Expected!(T, VkResult)`, following Vulkan's own rule that negative codes
    are errors and warnings such as `VK_SUBOPTIMAL_KHR` are not.))

Anything not wrapped stays reachable: `sparkles.vulkan.vulkan_c` is the raw surface,
and every abstraction here is additive over it.

Deliberately absent, for now: memory allocation (VMA is the field's settled
answer and is orthogonal), and any synchronisation or render-graph layer —
which the research catalog is emphatic belongs in a separate tier rather than
in the binding
($(LINK2 ../../../docs/research/vulkan/comparison.md, `comparison.md`)).
*/
module sparkles.vulkan;

public import sparkles.vulkan.api;
public import sparkles.vulkan.vulkan_c;
public import sparkles.vulkan.dispatch;
public import sparkles.vulkan.enumerate;
public import sparkles.vulkan.extensions;
public import sparkles.vulkan.loader;
public import sparkles.vulkan.result;
public import sparkles.vulkan.structure_type;
