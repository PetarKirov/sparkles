/**
Buffers and images bound to memory from `sparkles:vulkan`'s sub-allocator.

Each type creates its Vulkan object, asks the device what memory it needs —
through the Vulkan 1.1 queries where the device has them, which also say
whether it wants an allocation of its own — takes a region from a
`DeviceMemory`, and binds it. `destroy` undoes the three in reverse; nothing
here allocates device memory itself (`UVK27`).
*/
module sparkles.ui_vulkan.resources;

import expected : err, ok;

import sparkles.vulkan;

/// A buffer bound to a region of the sub-allocator's memory.
struct GpuBuffer
{
    VkBuffer handle;     ///
    DeviceRegion region; /// its memory; `region.host` maps it where host-visible
    ulong size;          /// bytes, as requested

    /**
    A buffer of `size` bytes for `usage`, in memory with the `required`
    properties, preferring the `preferred` ones. On failure nothing is left
    created or allocated.
    */
    static VkExpected!() create(B)(out GpuBuffer b, ref DeviceCommands device,
        ref DeviceMemory!B memory, ulong size, VkBufferUsageFlags usage,
        VkMemoryPropertyFlags required, VkMemoryPropertyFlags preferred = 0) @system
    {
        auto info = vkInfo(VkBufferCreateInfo(size: size, usage: usage,
            sharingMode: VkSharingMode.VK_SHARING_MODE_EXCLUSIVE));
        auto r = device.createBuffer(device.device, &info, null, &b.handle);
        if (r < 0)
            return err!void(r);
        auto request = bufferRequest(device, b.handle);
        request.required = required;
        request.preferred = preferred;
        request.tiling = Tiling.linear;
        auto region = memory.allocate(request);
        if (region.hasError)
        {
            device.destroyBuffer(device.device, b.handle, null);
            b = GpuBuffer.init;
            return err!void(region.error);
        }
        b.region = region.value;
        b.size = size;
        r = device.bindBufferMemory(device.device, b.handle, b.region.memory, b.region.offset);
        if (r < 0)
        {
            b.destroy(device, memory);
            return err!void(r);
        }
        return ok!VkResult();
    }

    /// Destroys the buffer and returns its memory; idempotent.
    void destroy(B)(ref DeviceCommands device, ref DeviceMemory!B memory) @system
    {
        if (handle !is null)
            device.destroyBuffer(device.device, handle, null);
        memory.deallocate(region);
        this = GpuBuffer.init;
    }
}

/// A two-dimensional, single-level, optimally tiled image, its memory and a
/// colour view of it.
struct GpuImage
{
    VkImage handle;      ///
    VkImageView view;    ///
    DeviceRegion region; ///
    VkFormat format;     ///
    VkExtent2D extent;   ///

    /**
    An image of `format` and `extent` for `usage`, in device-local memory
    where the device has it, with a colour view. On failure nothing is left
    created or allocated.
    */
    static VkExpected!() create(B)(out GpuImage image, ref DeviceCommands device,
        ref DeviceMemory!B memory, VkFormat format, VkExtent2D extent,
        VkImageUsageFlags usage) @system
    {
        auto info = vkInfo(VkImageCreateInfo(
            imageType: VkImageType.VK_IMAGE_TYPE_2D,
            format: format,
            extent: VkExtent3D(extent.width, extent.height, 1),
            mipLevels: 1,
            arrayLayers: 1,
            samples: VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT,
            tiling: VkImageTiling.VK_IMAGE_TILING_OPTIMAL,
            usage: usage,
            sharingMode: VkSharingMode.VK_SHARING_MODE_EXCLUSIVE,
            initialLayout: VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED,
        ));
        auto r = device.createImage(device.device, &info, null, &image.handle);
        if (r < 0)
            return err!void(r);
        image.format = format;
        image.extent = extent;
        auto request = imageRequest(device, image.handle);
        request.preferred = VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        request.tiling = Tiling.optimal;
        auto region = memory.allocate(request);
        if (region.hasError)
        {
            image.destroy(device, memory);
            return err!void(region.error);
        }
        image.region = region.value;
        r = device.bindImageMemory(device.device, image.handle, image.region.memory,
            image.region.offset);
        if (r < 0)
        {
            image.destroy(device, memory);
            return err!void(r);
        }
        auto viewInfo = vkInfo(VkImageViewCreateInfo(
            image: image.handle,
            viewType: VkImageViewType.VK_IMAGE_VIEW_TYPE_2D,
            format: format,
            subresourceRange: colourRange,
        ));
        r = device.createImageView(device.device, &viewInfo, null, &image.view);
        if (r < 0)
        {
            image.destroy(device, memory);
            return err!void(r);
        }
        return ok!VkResult();
    }

    /// Destroys the view and the image and returns their memory; idempotent.
    void destroy(B)(ref DeviceCommands device, ref DeviceMemory!B memory) @system
    {
        if (view !is null)
            device.destroyImageView(device.device, view, null);
        if (handle !is null)
            device.destroyImage(device.device, handle, null);
        memory.deallocate(region);
        this = GpuImage.init;
    }
}

/// The one mip level and layer of a colour image.
enum VkImageSubresourceRange colourRange = VkImageSubresourceRange(
    aspectMask: VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT,
    baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1);

private MemoryRequest bufferRequest(ref DeviceCommands device, VkBuffer buffer)
    @system nothrow @nogc
{
    if (device.has!vkVersion11)
    {
        auto dedicated = vkInfo(VkMemoryDedicatedRequirements());
        auto needs = vkInfo(VkMemoryRequirements2(pNext: &dedicated));
        auto info = vkInfo(VkBufferMemoryRequirementsInfo2(buffer: buffer));
        device.getBufferMemoryRequirements2(device.device, &info, &needs);
        return requestOf(needs.memoryRequirements, dedicated);
    }
    VkMemoryRequirements needs;
    device.getBufferMemoryRequirements(device.device, buffer, &needs);
    return requestOf(needs, VkMemoryDedicatedRequirements.init);
}

private MemoryRequest imageRequest(ref DeviceCommands device, VkImage image)
    @system nothrow @nogc
{
    if (device.has!vkVersion11)
    {
        auto dedicated = vkInfo(VkMemoryDedicatedRequirements());
        auto needs = vkInfo(VkMemoryRequirements2(pNext: &dedicated));
        auto info = vkInfo(VkImageMemoryRequirementsInfo2(image: image));
        device.getImageMemoryRequirements2(device.device, &info, &needs);
        return requestOf(needs.memoryRequirements, dedicated);
    }
    VkMemoryRequirements needs;
    device.getImageMemoryRequirements(device.device, image, &needs);
    return requestOf(needs, VkMemoryDedicatedRequirements.init);
}

private MemoryRequest requestOf(in VkMemoryRequirements needs,
    in VkMemoryDedicatedRequirements dedicated) @safe pure nothrow @nogc
{
    MemoryRequest request;
    request.size = needs.size;
    request.alignment = needs.alignment;
    request.typeBits = needs.memoryTypeBits;
    request.dedication = dedicated.requiresDedicatedAllocation ? Dedication.required
        : dedicated.prefersDedicatedAllocation ? Dedication.preferred
        : Dedication.none;
    return request;
}
