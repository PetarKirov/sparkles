/**
The device's memory: each heap's budget and usage, as `VK_EXT_memory_budget`
reports them, read at most once a second and kept at their peak (`PRF15` of
the profiling specification). A device without the extension reports
nothing, and says so.
*/
module sparkles.vulkan_wsi.memory_budget;

import core.time : Duration, MonoTime, seconds;

import sparkles.vulkan;

/// One heap: what the driver says the process may use, and uses.
struct HeapBudget
{
    ulong size;       /// the heap's size
    ulong budget;     /// what the process may use of it now
    ulong usage;      /// what the process uses
    ulong peakUsage;  /// the most it used at a sample
    bool deviceLocal; ///
}

/// ditto
struct MemoryPeaks
{
    enum maxHeaps = 16; /// `VK_MAX_MEMORY_HEAPS`
    HeapBudget[maxHeaps] heaps; ///
    uint heapCount; ///
    uint samples;   /// reads taken
    private MonoTime lastRead;

    /**
    Reads `vk`'s budget if a second has passed since the last read (or
    always, with `force`). False where the device has no budget, or it was
    too soon.
    */
    bool sample(Context)(ref Context vk, MonoTime now = MonoTime.currTime, bool force = false)
        @system
    {
        if (!vk.memoryBudget)
            return false;
        if (!force && samples && now - lastRead < 1.seconds)
            return false;
        auto budget = vkInfo(VkPhysicalDeviceMemoryBudgetPropertiesEXT());
        auto props = vkInfo(VkPhysicalDeviceMemoryProperties2(pNext: &budget));
        vk.instance.getPhysicalDeviceMemoryProperties2(vk.physicalDevice, &props);
        note(props.memoryProperties, budget);
        lastRead = now;
        return true;
    }

    /// Takes one reading: the heaps' sizes, budgets and usage.
    void note(in VkPhysicalDeviceMemoryProperties memory,
        in VkPhysicalDeviceMemoryBudgetPropertiesEXT budget) @safe pure nothrow @nogc
    {
        heapCount = memory.memoryHeapCount < maxHeaps ? memory.memoryHeapCount : maxHeaps;
        foreach (i; 0 .. heapCount)
        {
            auto h = &heaps[i];
            h.size = memory.memoryHeaps[i].size;
            h.deviceLocal = (memory.memoryHeaps[i].flags
                & VkMemoryHeapFlagBits.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0;
            h.budget = budget.heapBudget[i];
            h.usage = budget.heapUsage[i];
            if (h.usage > h.peakUsage)
                h.peakUsage = h.usage;
        }
        ++samples;
    }

    /// `heap 0 (device) peak 312.0 MiB of 7.8 GiB budget, heap 1 (host) …`.
    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text : writeInteger;

        static void size(ref Writer w, ulong bytes)
        {
            enum ulong mib = 1UL << 20, gib = 1UL << 30;
            const unit = bytes >= gib ? gib : mib;
            const tenths = (bytes * 10 + unit / 2) / unit;
            writeInteger(w, tenths / 10);
            put(w, '.');
            writeInteger(w, tenths % 10);
            put(w, unit == gib ? " GiB" : " MiB");
        }

        if (samples == 0)
        {
            put(w, "no budget reported");
            return;
        }
        foreach (i; 0 .. heapCount)
        {
            if (i)
                put(w, ", ");
            put(w, "heap ");
            writeInteger(w, i);
            put(w, heaps[i].deviceLocal ? " (device) peak " : " (host) peak ");
            size(w, heaps[i].peakUsage);
            put(w, " of ");
            size(w, heaps[i].budget);
            put(w, " budget");
        }
    }
}

///
@("vulkan_wsi.memory_budget.keepsThePeak")
@system pure nothrow @nogc unittest // the C structs default their pNext to void
{
    import sparkles.base.buffer : checkToString;

    MemoryPeaks p;
    checkToString(p, "no budget reported");
    VkPhysicalDeviceMemoryProperties memory;
    memory.memoryHeapCount = 2;
    memory.memoryHeaps[0] = VkMemoryHeap(size: 8UL << 30,
        flags: VkMemoryHeapFlagBits.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT);
    memory.memoryHeaps[1] = VkMemoryHeap(size: 16UL << 30);
    VkPhysicalDeviceMemoryBudgetPropertiesEXT budget;
    budget.heapBudget[0] = 7UL << 30;
    budget.heapBudget[1] = 12UL << 30;
    budget.heapUsage[0] = 300UL << 20;
    budget.heapUsage[1] = 20UL << 20;
    p.note(memory, budget);
    budget.heapUsage[0] = 100UL << 20; // freed since: the peak stays
    p.note(memory, budget);
    assert(p.samples == 2 && p.heaps[0].usage == 100UL << 20 && p.heaps[0].peakUsage == 300UL << 20);
    checkToString(p, "heap 0 (device) peak 300.0 MiB of 7.0 GiB budget, "
        ~ "heap 1 (host) peak 20.0 MiB of 12.0 GiB budget");
}
