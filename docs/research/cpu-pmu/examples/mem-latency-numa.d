#!/usr/bin/env dub
/+ dub.sdl:
    name "cpu_pmu_mem_latency_numa"
    platforms "linux"
    targetPath "build"
+/
/**
 * Precise memory-access sampling with data-source + NUMA-node attribution, pure D.
 *
 * The *precise data-source* concern of the analysis spine, exercised end to end
 * on the one engine that implements it on this host — AMD **IBS** (Instruction-
 * Based Sampling). It:
 *
 *   1. Opens the `ibs_op` PMU (its dynamic `type` read from
 *      `/sys/bus/event_source/devices/ibs_op/type`) with
 *      `PERF_SAMPLE_IP | ADDR | DATA_SRC | WEIGHT` (+ `PHYS_ADDR` when the host
 *      permits it), then strides a buffer larger than L3 to provoke DRAM loads.
 *      The kernel forwards a core-PMU `precise_ip` request to exactly this PMU
 *      (`forward_event_to_ibs`, `arch/x86/events/amd/ibs.c`); AMD has **no**
 *      PEBS, so the `cpu` PMU reports `max_precise == 0` and IBS is the *only*
 *      precise engine — the `cpu`/`precise_ip` fallback below is Intel-only and
 *      stays unexercised here.
 *   2. Decodes each sample's `perf_mem_data_src` union (the same bitfields the
 *      IBS driver fills from `IBS_OP_DATA2`/`DATA3`) into human level/op/snoop/
 *      TLB strings, matching `tools/perf/util/mem-events.c`.
 *   3. Classifies each sampled *data* address to a NUMA node two ways —
 *      `get_mempolicy(MPOL_F_NODE | MPOL_F_ADDR)` and `move_pages()` query mode
 *      (raw syscalls; see the note on libnuma below) — and compares them against
 *      the workload buffer's home node. This box is single-node, so every
 *      address resolves to node 0: the API round-trip is demonstrated, the
 *      cross-node *classification* is not (recorded as a host limit).
 *
 * `get_mempolicy`/`move_pages` are NOT in glibc (they live in libnuma, whose
 * functions are themselves thin syscall wrappers) and numactl ships no
 * `numa.pc`, so a `libs "numa"` link would be a hard build-time dependency that
 * a host without libnuma cannot satisfy — defeating "green on any host". We call
 * the two syscalls directly through the libc `syscall(2)` wrapper instead: no
 * external C library, identical kernel path.
 *
 * Companion to docs/research/cpu-pmu/precise-sampling.md
 *   § "Data-source & data-address sampling: AMD IBS" and
 *   § "From data address to NUMA node".
 *
 * Run with: dub run --single mem-latency-numa.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX (Zen 4, family 0x19
 * model 0x61; `ibs_op` type 11, `zen4_ibs_extensions=1`), single NUMA node,
 * `/proc/sys/kernel/perf_event_paranoid` = -1, numactl 2.0.19 (headers only —
 * not linked), LDC 1.41 druntime `core.sys.linux.perf_event`.
 *
 * Portability: no precise PMU (no IBS and `cpu` `max_precise == 0`), a refused
 * `perf_event_open` (`perf_event_paranoid`, seccomp), no data-address samples,
 * or a non-Linux/non-NUMA host each print a `SKIP:` or reduced line and exit 0,
 * so CI stays green on any host.
 */
module cpu_pmu_mem_latency_numa;

version (linux)
{
    import core.sys.linux.perf_event;
    import core.sys.posix.unistd : close, sysconf, _SC_PAGESIZE;
    import core.sys.posix.sys.mman : mmap, munmap, PROT_READ, PROT_WRITE,
        MAP_SHARED, MAP_PRIVATE, MAP_FAILED;
    import core.atomic : atomicLoad, atomicStore, MemoryOrder;
    import std.stdio : writefln, writeln;
    import std.algorithm : sort, min;

    // ---- libc / kernel seams -------------------------------------------------

    // Anonymous mapping for the workload buffer (Linux value; the druntime posix
    // binding does not export MAP_ANON uniformly).
    enum MAP_ANON = 0x20;

    // PERF_SAMPLE_* live in a named D enum, so hoist the few this probe uses to
    // unqualified manifest constants for readable sample_type expressions.
    enum PERF_SAMPLE_IP        = perf_event_sample_format.PERF_SAMPLE_IP;
    enum PERF_SAMPLE_ADDR      = perf_event_sample_format.PERF_SAMPLE_ADDR;
    enum PERF_SAMPLE_WEIGHT    = perf_event_sample_format.PERF_SAMPLE_WEIGHT;
    enum PERF_SAMPLE_DATA_SRC  = perf_event_sample_format.PERF_SAMPLE_DATA_SRC;
    enum PERF_SAMPLE_PHYS_ADDR = perf_event_sample_format.PERF_SAMPLE_PHYS_ADDR;

    // get_mempolicy(2) / move_pages(2) via the libc syscall wrapper. Numbers are
    // per-arch; verified against arch/x86/entry/syscalls/syscall_64.tbl (239 /
    // 279) and include/uapi/asm-generic/unistd.h (236 / 239) in the 7.1-rc6 tree.
    extern (C) long syscall(long number, ...) @nogc nothrow;

    version (X86_64)      { enum SYS_get_mempolicy = 239; enum SYS_move_pages = 279; enum nodeSyscalls = true; }
    else version (AArch64){ enum SYS_get_mempolicy = 236; enum SYS_move_pages = 239; enum nodeSyscalls = true; }
    else version (RISCV64){ enum SYS_get_mempolicy = 236; enum SYS_move_pages = 239; enum nodeSyscalls = true; }
    else                  { enum SYS_get_mempolicy = 0;   enum SYS_move_pages = 0;   enum nodeSyscalls = false; }

    // set_mempolicy(2)/get_mempolicy(2) flags — include/uapi/linux/mempolicy.h.
    enum MPOL_F_NODE = 1 << 0; // return the node of `addr` (with MPOL_F_ADDR)
    enum MPOL_F_ADDR = 1 << 1; // look the vma up by address

    // Pin to one CPU so IBS per-thread sampling and the "home node" are stable.
    extern (C) int sched_setaffinity(int pid, size_t cpusetsize, const(void)* mask) @nogc nothrow;

    // ---- perf_mem_data_src decode (include/uapi/linux/perf_event.h) ----------
    //
    // The union is one u64 of contiguous bitfields; the shifts below are the
    // documented field positions. Constant names/values are the PERF_MEM_*
    // macros; the strings mirror tools/perf/util/mem-events.c so the decode
    // reads the same as `perf report -D`.

    ulong bits(ulong v, uint shift, uint width) @safe pure nothrow @nogc
        => (v >> shift) & ((1UL << width) - 1);

    string memOpStr(ulong ds) @safe pure nothrow @nogc
    {
        const op = bits(ds, 0, 5);
        if (op & 0x02) return "LOAD";
        if (op & 0x04) return "STORE";
        if (op & 0x08) return "PFETCH";
        if (op & 0x10) return "EXEC";
        return "N/A";
    }

    // Composite level via mem_lvl_num (shift 33) + remote (37) + hops (43),
    // the path perf_mem__lvl_scnprintf takes when lvl_num is set.
    string memLvlStr(ulong ds) @safe nothrow
    {
        static immutable string[16] lvlnum = [
            0x1: "L1", 0x2: "L2", 0x3: "L3", 0x4: "L4", 0x5: "L2 MHB",
            0x6: "Memory-side Cache", 0x7: "L0", 0x8: "Uncached", 0x9: "CXL",
            0xa: "I/O", 0xb: "Any cache", 0xc: "LFB/MAB", 0xd: "RAM",
            0xe: "PMEM", 0xf: "N/A",
        ];
        static immutable string[5] hops = [
            "N/A", "core, same node", "node, same socket",
            "socket, same board", "board",
        ];
        const lvl = bits(ds, 5, 14);
        const hit = (lvl & 0x02) ? "hit" : (lvl & 0x04) ? "miss" : "";
        const num = cast(uint) bits(ds, 33, 4);
        if (num != 0 && num != 0xf)
        {
            string s;
            if (bits(ds, 37, 1)) s ~= "Remote ";
            const h = cast(uint) bits(ds, 43, 3);
            if (h != 0) s ~= hops[h] ~ " ";
            s ~= lvlnum[num];
            if (hit.length) s ~= " " ~ hit;
            return s;
        }
        return "N/A";
    }

    string snoopStr(ulong ds) @safe pure nothrow @nogc
    {
        const s = bits(ds, 19, 5);
        if (s & 0x10) return "HitM";
        if (s & 0x08) return "Miss";
        if (s & 0x04) return "Hit";
        if (s & 0x02) return "None";
        if (bits(ds, 38, 2) & 0x02) return "Peer";
        if (bits(ds, 38, 2) & 0x01) return "Fwd";
        return "N/A";
    }

    string tlbStr(ulong ds) @safe pure nothrow
    {
        const t = bits(ds, 26, 7);
        const where = (t & 0x08) ? "L1" : (t & 0x10) ? "L2" : (t & 0x20) ? "walker" : "";
        const hm = (t & 0x02) ? " hit" : (t & 0x04) ? " miss" : "";
        if (where.length) return where ~ hm;
        return "N/A";
    }

    // ---- NUMA node oracles ---------------------------------------------------

    /// Node of the page containing `addr`, or a negative -errno, via
    /// get_mempolicy(MPOL_F_NODE | MPOL_F_ADDR). numaif.h:
    ///   long get_mempolicy(int *mode, ulong *nmask, ulong maxnode,
    ///                      void *addr, ulong flags);
    /// with these flags, `mode` receives the node number.
    int nodeViaGetMempolicy(void* addr) @trusted @nogc nothrow
    {
        static if (!nodeSyscalls) return -1;
        else
        {
            int node = -1;
            const r = syscall(SYS_get_mempolicy, &node, null, 0UL, addr,
                cast(ulong)(MPOL_F_NODE | MPOL_F_ADDR));
            return r == 0 ? node : cast(int) r;
        }
    }

    /// Node of the page containing `addr` via move_pages() query mode (nodes ==
    /// NULL). numaif.h:
    ///   long move_pages(int pid, ulong count, void **pages,
    ///                   const int *nodes, int *status, int flags);
    /// `status[0]` receives the node number (or a negative -errno).
    int nodeViaMovePages(void* addr, size_t pageSize) @trusted @nogc nothrow
    {
        static if (!nodeSyscalls) return -1;
        else
        {
            void* page = cast(void*)(cast(size_t) addr & ~(pageSize - 1));
            int status = int.min;
            const r = syscall(SYS_move_pages, 0, 1UL, &page, null, &status, 0UL);
            return r == 0 ? status : cast(int) r;
        }
    }

    // ---- sysfs helper --------------------------------------------------------

    /// Reads a small unsigned integer from a sysfs file, or -1 on any failure.
    long readSysLong(string path) @trusted
    {
        import std.file : readText;
        import std.string : strip;
        import std.conv : to;

        try
            return readText(path).strip.to!long;
        catch (Exception)
            return -1;
    }

    // ---- the workload --------------------------------------------------------

    __gshared ulong sink;

    /// Lay out `words` as one random permutation cycle of its own indices
    /// (Sattolo's algorithm → a single cycle). Chasing `i = words[i]` is then a
    /// dependent load per step whose target is unpredictable, so on a working set
    /// wider than L3 nearly every step misses to DRAM — the classic pointer-chase
    /// memory-latency pattern. Also faults every page in before classification.
    void buildChase(size_t[] words) @safe
    {
        foreach (i; 0 .. words.length)
            words[i] = i;
        ulong rng = 0x9E3779B97F4A7C15UL;
        for (size_t i = words.length - 1; i > 0; i--)
        {
            rng = rng * 6364136223846793005UL + 1442695040888963407UL;
            const j = cast(size_t)(rng % i); // 0 <= j < i keeps it a single cycle
            const t = words[i];
            words[i] = words[j];
            words[j] = t;
        }
    }

    /// `steps` dependent chases from `start`; returns the landing index (folded
    /// into a __gshared sink by the caller so the loads survive DCE).
    size_t chase(const size_t[] words, size_t start, size_t steps) @safe
    {
        size_t i = start;
        foreach (_; 0 .. steps)
            i = words[i];
        return i;
    }

    // ---- perf ring-buffer reader ---------------------------------------------

    /// Copies `n` bytes out of the perf data area at logical offset `logicalTail`
    /// (which may straddle the ring's wrap point) into `dst`.
    void ringCopy(void* dst, const(ubyte)* dataStart, ulong dataSize, ulong logicalTail, size_t n) @system
    {
        auto d = cast(ubyte*) dst;
        const off = cast(size_t)(logicalTail % dataSize);
        foreach (i; 0 .. n)
            d[i] = dataStart[(off + i) % dataSize];
    }

    /// One decoded PERF_RECORD_SAMPLE (only the fields this probe requests).
    struct Sample
    {
        ulong ip, addr, weight, dataSrc, physAddr;
    }

    int run()
    {
        const pageSize = cast(size_t) sysconf(_SC_PAGESIZE);

        // ---- locate a precise-sampling PMU ----------------------------------
        bool viaIbs = true;
        long pmuType = readSysLong("/sys/bus/event_source/devices/ibs_op/type");
        int maxPrecise = 0;
        if (pmuType < 0)
        {
            viaIbs = false;
            maxPrecise = cast(int) readSysLong("/sys/bus/event_source/devices/cpu/caps/max_precise");
            if (maxPrecise <= 0)
            {
                writefln("SKIP: no precise-sampling PMU — no AMD IBS (`ibs_op`) and "
                    ~ "`cpu` max_precise == %d (Intel needs PEBS/precise_ip>0)", maxPrecise);
                return 0;
            }
            pmuType = perf_type_id.PERF_TYPE_HARDWARE; // cpu-PMU precise fallback
        }
        const zen4 = readSysLong("/sys/bus/event_source/devices/ibs_op/caps/zen4_ibs_extensions") == 1;

        // ---- NUMA topology --------------------------------------------------
        int nodesOnline = 1;
        {
            import std.file : dirEntries, SpanMode, exists;
            import std.algorithm : startsWith;
            import std.path : baseName;

            if (exists("/sys/devices/system/node"))
            {
                int c = 0;
                foreach (e; dirEntries("/sys/devices/system/node", SpanMode.shallow))
                    if (e.baseName.startsWith("node"))
                        c++;
                if (c > 0)
                    nodesOnline = c;
            }
        }

        // Pin to CPU 0 for a stable per-thread IBS context and home node.
        ulong[16] cpuMask;
        cpuMask[0] = 1;
        sched_setaffinity(0, cpuMask.sizeof, cpuMask.ptr);

        // ---- workload buffer + its home node --------------------------------
        enum bufBytes = 64 * 1024 * 1024; // > per-CCX L3, so misses reach DRAM
        void* raw = mmap(null, bufBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (raw == MAP_FAILED)
        {
            writefln("SKIP: could not mmap a %d MiB workload buffer", bufBytes >> 20);
            return 0;
        }
        auto words = (cast(size_t*) raw)[0 .. bufBytes / size_t.sizeof];
        buildChase(words); // also faults every page in before classifying
        const homeNode = nodeViaGetMempolicy(raw);

        // ---- open the sampling event ----------------------------------------
        // Try richest sample set first (with PHYS_ADDR), then drop PHYS_ADDR;
        // and prefer kernel exclusion, then fall back to unfiltered — so a
        // stricter host still yields a working event.
        //
        // IBS filtering surprise: this Zen 4 lacks IBS_CAPS_BIT63_FILTER, so a
        // bare `exclude_kernel`/`exclude_hv` is EINVAL (perf_ibs_init,
        // arch/x86/events/amd/ibs.c). Kernel/user filtering must instead engage
        // the software filter — the `swfilt` bit (config2:0, IBS_SW_FILTER_MASK).
        // `exclude_hv` is never set: IBS rejects it outright.
        enum swfilt = 1UL; // config2:0
        enum baseType = PERF_SAMPLE_IP | PERF_SAMPLE_ADDR | PERF_SAMPLE_DATA_SRC | PERF_SAMPLE_WEIGHT;
        int fd = -1;
        ulong sampleType;
        foreach (withPhys; [true, false])
            foreach (exclKernel; [1, 0])
            {
                perf_event_attr attr;
                attr.size = perf_event_attr.sizeof;
                attr.type = cast(uint) pmuType;
                attr.config = 0; // ibs_op: cnt_ctl=0 (cycles), no ldlat filter
                attr.config2 = (viaIbs && exclKernel) ? swfilt : 0;
                attr.sample_period = 20_000; // ibs_op min_period is 0x90
                sampleType = baseType | (withPhys ? PERF_SAMPLE_PHYS_ADDR : 0);
                attr.sample_type = sampleType;
                attr.disabled = 1;
                attr.exclude_kernel = exclKernel;
                if (!viaIbs)
                    attr.precise_ip = maxPrecise; // cpu-PMU (Intel) fallback path
                fd = cast(int) perf_event_open(&attr, 0, -1, -1, 0);
                if (fd >= 0)
                    goto opened;
            }
    opened:
        if (fd < 0)
        {
            writefln("SKIP: perf_event_open on %s failed — perf_event_paranoid, "
                ~ "seccomp, or unsupported sample type", viaIbs ? "ibs_op" : "cpu");
            munmap(raw, bufBytes);
            return 0;
        }

        // ---- mmap the sample ring -------------------------------------------
        enum dataPages = 128; // power of two
        const mmapBytes = (1 + dataPages) * pageSize;
        void* ring = mmap(null, mmapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ring == MAP_FAILED)
        {
            writefln("SKIP: could not mmap the perf ring buffer");
            close(fd);
            munmap(raw, bufBytes);
            return 0;
        }
        auto meta = cast(perf_event_mmap_page*) ring;
        const dataStart = cast(const(ubyte)*) ring + meta.data_offset;
        const dataSize = meta.data_size;

        // ---- sample: enable, stride, drain ----------------------------------
        import core.sys.posix.sys.ioctl : ioctl;
        import core.stdc.config : c_ulong;

        Sample[] samples;
        ulong totalRecords, lostRecords;

        void drain() @trusted
        {
            auto head = atomicLoad!(MemoryOrder.acq)(*cast(shared(ulong)*)&meta.data_head);
            auto tail = meta.data_tail;
            while (tail < head)
            {
                perf_event_header hdr;
                ringCopy(&hdr, dataStart, dataSize, tail, hdr.sizeof);
                if (hdr.type == perf_event_type.PERF_RECORD_SAMPLE)
                {
                    ubyte[256] rec;
                    ringCopy(rec.ptr, dataStart, dataSize, tail, min(hdr.size, rec.length));
                    size_t cur = hdr.sizeof;
                    ulong take() { const v = *cast(ulong*)(rec.ptr + cur); cur += 8; return v; }
                    Sample s;
                    if (sampleType & PERF_SAMPLE_IP)        s.ip = take();
                    if (sampleType & PERF_SAMPLE_ADDR)      s.addr = take();
                    if (sampleType & PERF_SAMPLE_WEIGHT)    s.weight = take();
                    if (sampleType & PERF_SAMPLE_DATA_SRC)  s.dataSrc = take();
                    if (sampleType & PERF_SAMPLE_PHYS_ADDR) s.physAddr = take();
                    samples ~= s;
                    totalRecords++;
                }
                else if (hdr.type == perf_event_type.PERF_RECORD_LOST)
                    lostRecords++;
                tail += hdr.size;
            }
            atomicStore!(MemoryOrder.rel)(*cast(shared(ulong)*)&meta.data_tail, head);
        }

        ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_RESET, 0);
        ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_ENABLE, 0);
        size_t pos;
        foreach (pass; 0 .. 200)
        {
            pos = chase(words, pos, 100_000);
            sink += pos;
            drain();
            if (samples.length >= 4000)
                break;
        }
        ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_DISABLE, 0);
        drain();

        munmap(ring, mmapBytes);
        close(fd);

        // ---- report ---------------------------------------------------------
        writefln("== precise memory-access sampling: %s ==", viaIbs
            ? (zen4 ? "AMD IBS (ibs_op, zen4_ibs_extensions)" : "AMD IBS (ibs_op)")
            : "cpu PMU precise_ip (Intel PEBS path — UNVERIFIED on this host)");
        writefln("  PMU type=%d  period=20000  sample_type=IP|ADDR|DATA_SRC|WEIGHT%s",
            pmuType, (sampleType & PERF_SAMPLE_PHYS_ADDR) ? "|PHYS_ADDR" : "");
        writefln("  workload=%d MiB  home node(get_mempolicy)=%d  NUMA nodes online=%d",
            bufBytes >> 20, homeNode, nodesOnline);
        if (nodesOnline <= 1)
            writeln("  (single-node host: node round-trip is demonstrated; cross-node "
                ~ "classification is not — that needs a multi-socket box)");

        // Keep only samples with a resolved data address (IBS sets ADDR only when
        // DcLinAddrValid). Classify each such address to a node, both ways.
        struct Row { Sample s; int nGmp, nMvp; }
        Row[] rows;
        foreach (s; samples)
            if (s.addr != 0 && memOpStr(s.dataSrc) != "N/A")
                rows ~= Row(s, nodeViaGetMempolicy(cast(void*) s.addr),
                    nodeViaMovePages(cast(void*) s.addr, pageSize));

        if (rows.length == 0)
        {
            writefln("  collected %d raw samples, %d with a usable data address — "
                ~ "reduced output (no per-address rows to show)", samples.length, rows.length);
            munmap(raw, bufBytes);
            return 0;
        }

        // Lead with samples that missed the L1 — those exercise the whole
        // data-source/latency path; pad with L1 hits if there are few.
        Row[] show;
        foreach (r; rows)
            if (memLvlStr(r.s.dataSrc) != "L1 hit" && show.length < 8)
                show ~= r;
        foreach (r; rows)
            if (show.length < 8)
                show ~= r;
        writefln("\n  sampled data accesses (%d of %d; cache-miss samples first):",
            show.length, rows.length);
        writeln("    ip                 addr               op     level              "
            ~ "snoop  tlb      lat  node[gmp/mvp]");
        foreach (r; show)
            writefln("    0x%016x 0x%016x %-6s %-18s %-6s %-8s %4d  %d/%d",
                r.s.ip, r.s.addr, memOpStr(r.s.dataSrc), memLvlStr(r.s.dataSrc),
                snoopStr(r.s.dataSrc), tlbStr(r.s.dataSrc), r.s.weight, r.nGmp, r.nMvp);

        // Level histogram + node-agreement summary.
        ulong[string] lvlHist;
        int agreeHome, disagree, gmpErr, mvpErr;
        ulong[] lats;
        foreach (r; rows)
        {
            lvlHist[memLvlStr(r.s.dataSrc)]++;
            if (r.nGmp < 0) gmpErr++;
            if (r.nMvp < 0) mvpErr++;
            if (r.nGmp >= 0 && r.nMvp >= 0)
            {
                if (r.nGmp == homeNode && r.nMvp == homeNode) agreeHome++;
                else disagree++;
            }
            if (r.s.weight > 0) lats ~= r.s.weight;
        }
        writefln("\n  data-source levels across %d resolved samples:", rows.length);
        foreach (k, v; lvlHist)
            writefln("    %-24s %d", k, v);
        writefln("  node classification: %d on home node %d (get_mempolicy == move_pages), "
            ~ "%d elsewhere; gmp errors=%d, mvp errors=%d",
            agreeHome, homeNode, disagree, gmpErr, mvpErr);
        if (lats.length)
        {
            lats.sort();
            writefln("  DC-miss latency (WEIGHT) on %d load samples: min=%d median=%d max=%d cycles",
                lats.length, lats[0], lats[$ / 2], lats[$ - 1]);
        }
        else
            writeln("  DC-miss latency (WEIGHT): none — no sampled load missed the data cache");

        munmap(raw, bufBytes);
        return 0;
    }
}

int main()
{
    version (linux)
        return run();
    else
    {
        import std.stdio : writefln;

        writefln("SKIP: perf_event_open / IBS is Linux-only");
        return 0;
    }
}
