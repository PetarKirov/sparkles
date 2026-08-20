/**
A command pool and the buffers allocated from it.

Thin on purpose: Vulkan's command-pool API is already close to what a frame
loop wants, and the only decisions worth making once are the pool's reset
strategy and its lifetime against the queue family.

$(B One buffer per frame in flight, not per image.) A command buffer is
rerecorded by the CPU, so what bounds it is how far the CPU may run ahead —
$(REF FrameSync.framesInFlight, sparkles,vulkan_wsi,frame) — not how many images
the presentation engine happens to own. Sizing by image count works and wastes
a buffer whenever a driver reports more images than the loop keeps in flight.

$(B `RESET_COMMAND_BUFFER`, so a buffer resets itself.) The alternative is
resetting the whole pool each frame, which is cheaper for a loop that
rerecords everything and wrong for one that does not: it invalidates every
buffer from the pool at once, including any a caller is holding for a later
frame. Per-buffer reset costs a little more bookkeeping in the driver and
composes.
*/
module sparkles.vulkan_wsi.commands;

import expected : err, ok;

import sparkles.vulkan;
import sparkles.vulkan_wsi.error;

version (unittest)
    import sparkles.vulkan_wsi.context : VulkanContext;

/// A command pool bound to the context's queue family, plus its primary buffers.
struct CommandPool
{
    VkCommandPool handle;

    /// Primary buffers, owned by the pool — freeing them individually is optional.
    VkCommandBuffer[] buffers;

    @disable this(this);

    /// Create a pool on `vk`'s graphics/present family and allocate `count` buffers.
    static PresentationResult!void create(Context)(out CommandPool pool,
        ref Context vk, uint count)
        @system nothrow
    in (count > 0, "a pool with no buffers has nothing to record into")
    {
        auto poolInfo = vkInfo(VkCommandPoolCreateInfo(
            // The frame loop rerecords one buffer per frame; see the module
            // note on why this is not a whole-pool reset.
            flags: VkCommandPoolCreateFlagBits.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            queueFamilyIndex: vk.queueFamily,
        ));

        auto created = vk.device.createCommandPool(
            vk.device.device, &poolInfo, null, &pool.handle).check;
        if (created.hasError)
            return err!void("vkCreateCommandPool: " ~ describeResult(created.error));

        pool.buffers = new VkCommandBuffer[count];
        auto allocInfo = vkInfo(VkCommandBufferAllocateInfo(
            commandPool: pool.handle,
            level: VkCommandBufferLevel.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            commandBufferCount: count,
        ));

        auto allocated = vk.device.allocateCommandBuffers(
            vk.device.device, &allocInfo, pool.buffers.ptr).check;
        if (allocated.hasError)
        {
            pool.destroy(vk);
            return err!void("vkAllocateCommandBuffers: " ~ describeResult(allocated.error));
        }

        return ok!string();
    }

    /**
    Reset buffer `index` and begin recording into it.

    `ONE_TIME_SUBMIT` tells the driver the recording will be submitted once and
    then rerecorded, which is true of every frame loop here and lets it skip
    keeping the buffer replayable.
    */
    VkExpected!VkCommandBuffer begin(Context)(ref Context vk, uint index)
        @system nothrow
    in (index < buffers.length, "buffer index is out of range")
    {
        auto cmd = buffers[index];

        auto reset = check(vk.device.resetCommandBuffer(cmd, 0));
        if (reset.hasError)
            return err!VkCommandBuffer(reset.error);

        auto info = vkInfo(VkCommandBufferBeginInfo(
            flags: VkCommandBufferUsageFlagBits.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        ));

        return check(vk.device.beginCommandBuffer(cmd, &info), cmd);
    }

    /// Finish recording into buffer `index`.
    VkExpected!void end(Context)(ref Context vk, uint index) @system nothrow
    in (index < buffers.length, "buffer index is out of range")
        => check(vk.device.endCommandBuffer(buffers[index]));

    /**
    Destroy the pool.

    The buffers go with it: `vkDestroyCommandPool` frees everything allocated
    from the pool, so freeing them first would be redundant.
    */
    void destroy(Context)(ref Context vk) @system nothrow
    {
        if (handle !is null && vk.device.device !is null
            && vk.device.destroyCommandPool !is null)
        {
            vk.device.destroyCommandPool(vk.device.device, handle, null);
            handle = null;
        }
        buffers = null;
    }
}

@("vulkan_wsi.commands.destroyIsIdempotentWithoutADevice")
@system nothrow unittest
{
    // `create` destroys its own partial state when buffer allocation fails,
    // and the caller may destroy again. Neither path may touch a null device.
    VulkanContext vk;
    CommandPool pool;
    pool.destroy(vk);
    pool.destroy(vk);
    assert(pool.handle is null);
    assert(pool.buffers.length == 0);
}
