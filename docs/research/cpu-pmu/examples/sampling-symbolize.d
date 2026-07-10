#!/usr/bin/env dub
/+ dub.sdl:
    name "cpu_pmu_sampling_symbolize"
    platforms "linux"
    libs "dw" "elf"
    dflags "-g"
    targetPath "build"
+/
/**
 * Overflow/IP sampling through the `perf_event` mmap ring buffer, then
 * symbolization of the sampled instruction pointers via elfutils `libdwfl`.
 *
 * This is the end-to-end "profiler core": a hardware event (`cycles`) is armed
 * with a target sample *frequency*; on each overflow the kernel writes a
 * `PERF_RECORD_SAMPLE` (carrying the interrupted IP) into a memory-mapped ring
 * buffer. We drain the ring, then hand the *live* process to `libdwfl`
 * (`dwfl_linux_proc_report`, the library's own `/proc/PID/maps` reader) and
 * resolve each IP to module → symbol (`dwfl_module_addrinfo`) → source line
 * (`dwfl_module_getsrc` + `dwfl_lineinfo`).
 *
 * A key, verified subtlety about `PERF_RECORD_MMAP2` (`attr.mmap2 = 1`): the
 * kernel emits it only for executable mappings **created while the event is
 * enabled** — it does NOT re-emit pre-existing code (our own binary, libc).
 * That is why the `perf` tool *synthesizes* `MMAP2` for the already-mapped
 * regions from `/proc/PID/maps` at start, and why `libdwfl`'s
 * `dwfl_linux_proc_report` reads the same file. To make a real captured
 * `MMAP2` visible, we deliberately map `/proc/self/exe` `PROT_EXEC` mid-window;
 * its record's `filename` matches the binary `libdwfl` symbolizes against —
 * tying the two halves of the address-space model together.
 *
 * Companion to docs/research/cpu-pmu/linux-perf-events.md
 *   § "Overflow sampling: the ring buffer, `PERF_RECORD_MMAP2`, and IP
 *      symbolization" and docs/research/cpu-pmu/elfutils.md § "Address →
 *      module → symbol → line".
 *
 * Run with: nix shell nixpkgs#elfutils nixpkgs#pkg-config -c dub run --single sampling-symbolize.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX (Zen 4),
 * `/proc/sys/kernel/perf_event_paranoid` = -1, elfutils 0.195 (libdw/libdwfl),
 * LDC 1.41 druntime `core.sys.linux.perf_event`.
 *
 * Portability: any missing capability (`perf_event_open`/`mmap` refused by
 * `perf_event_paranoid`/seccomp, no PMU, non-Linux) prints a `SKIP:` line and
 * exits 0 so CI stays green on any host. A binary with no DWARF line table just
 * prints symbol names without `file:line` — also a success.
 */
module cpu_pmu_sampling_symbolize;

version (linux)
{
    import core.sys.linux.perf_event;
    import core.sys.posix.unistd : close, getpid, sysconf, _SC_PAGESIZE;
    import core.sys.posix.fcntl : open, O_RDONLY;
    import core.sys.posix.sys.ioctl : ioctl;
    import core.sys.posix.sys.mman : mmap, munmap, PROT_READ, PROT_WRITE, PROT_EXEC,
        MAP_SHARED, MAP_PRIVATE, MAP_FAILED;
    import core.stdc.config : c_ulong;
    import core.stdc.string : memcpy, strlen;
    import core.atomic : atomicLoad, atomicStore, MemoryOrder;
    import core.time : MonoTime, msecs;
    import std.stdio : writefln, writeln;
    import std.string : fromStringz;

    // ---- elfutils libdwfl: extern(C) prototypes declared in-file --------
    // (a single-file dub program cannot compile a C shim; we link -ldw -lelf).
    alias Dwarf_Addr = ulong;
    alias Dwarf_Word = ulong;
    alias GElf_Addr = ulong;
    alias GElf_Off = ulong;
    alias GElf_Word = uint;

    /// `Elf64_Sym` (== `GElf_Sym` on LP64) — dwfl fills this; we read `st_value`.
    struct GElf_Sym
    {
        uint st_name;
        ubyte st_info;
        ubyte st_other;
        ushort st_shndx;
        ulong st_value;
        ulong st_size;
    }

    struct Dwfl; // opaque
    struct Dwfl_Module; // opaque
    struct Dwfl_Line; // opaque
    struct Elf; // opaque

    /// `Dwfl_Callbacks` (elfutils@6f8f78c libdwfl/libdwfl.h:72) as four pointers:
    /// `find_elf`, `find_debuginfo`, `section_address`, `debuginfo_path`.
    struct DwflCallbacks
    {
        void* find_elf;
        void* find_debuginfo;
        void* section_address;
        char** debuginfo_path;
    }

    extern (C) @nogc nothrow
    {
        Dwfl* dwfl_begin(const(DwflCallbacks)*);
        void dwfl_end(Dwfl*);
        int dwfl_linux_proc_report(Dwfl*, int pid);
        int dwfl_report_end(Dwfl*, void* removed, void* arg);
        Dwfl_Module* dwfl_addrmodule(Dwfl*, Dwarf_Addr);
        const(char)* dwfl_module_addrinfo(Dwfl_Module*, GElf_Addr, GElf_Off*,
            GElf_Sym*, GElf_Word*, Elf**, Dwarf_Addr*);
        Dwfl_Line* dwfl_module_getsrc(Dwfl_Module*, Dwarf_Addr);
        const(char)* dwfl_lineinfo(Dwfl_Line*, Dwarf_Addr*, int*, int*, Dwarf_Word*, Dwarf_Word*);
        // The two standard callbacks we take the address of for DwflCallbacks:
        int dwfl_linux_proc_find_elf();
        int dwfl_standard_find_debuginfo();
    }

    // ---- captured records -----------------------------------------------
    struct Mapping
    {
        ulong addr, len, pgoff;
        uint prot;
        string filename;
    }

    __gshared ulong sink;

    /// Two deliberately non-inlined hot functions, so sampled IPs land in
    /// named symbols we can point at.
    pragma(inline, false) ulong mixHash(ulong x)
    {
        foreach (_; 0 .. 96)
            x = (x * 6364136223846793005UL + 1442695040888963407UL) ^ (x >> 29);
        return x;
    }

    pragma(inline, false) ulong sumSquares(ulong n)
    {
        ulong s = 0;
        foreach (i; 0 .. n)
            s += i * i;
        return s;
    }

    void workload()
    {
        auto deadline = MonoTime.currTime + 500.msecs;
        ulong acc = 0x1234_5678_9ABC_DEF0UL;
        while (MonoTime.currTime < deadline)
        {
            acc += mixHash(acc);
            acc += sumSquares(2048);
        }
        sink += acc;
    }

    int run()
    {
        const pageSize = cast(size_t) sysconf(_SC_PAGESIZE);
        enum dataPages = 256; // power of two
        const dataSize = dataPages * pageSize;
        const mmapSize = (1 + dataPages) * pageSize;

        // Sampling event: cycles at ~4 kHz, user-space only so every IP is
        // symbolizable against the process image. IP+TID+TIME per sample; the
        // kernel also emits MMAP2 for executable mappings (attr.mmap2 = 1).
        perf_event_attr attr;
        attr.size = perf_event_attr.sizeof;
        attr.type = perf_type_id.PERF_TYPE_HARDWARE;
        attr.config = perf_hw_id.PERF_COUNT_HW_CPU_CYCLES;
        attr.sample_type = perf_event_sample_format.PERF_SAMPLE_IP
            | perf_event_sample_format.PERF_SAMPLE_TID
            | perf_event_sample_format.PERF_SAMPLE_TIME;
        attr.freq = 1;
        attr.sample_freq = 4000;
        attr.disabled = 1;
        attr.exclude_kernel = 1;
        attr.exclude_hv = 1;
        attr.mmap = 1;
        attr.mmap2 = 1;

        int fd = (() @trusted => cast(int) perf_event_open(&attr, 0, -1, -1, 0))();
        if (fd < 0)
        {
            writefln("SKIP: perf_event_open (sampling) failed — perf_event_paranoid, "
                ~ "seccomp, or no PMU on this host");
            return 0;
        }

        void* base = (() @trusted => mmap(null, mmapSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0))();
        if (base is MAP_FAILED)
        {
            writefln("SKIP: mmap of the perf ring buffer failed "
                ~ "(perf_event_mlock_kb too small?)");
            close(fd);
            return 0;
        }
        auto meta = cast(perf_event_mmap_page*) base;
        auto dataArea = cast(ubyte*) base + pageSize;

        // A fresh PROT_EXEC mapping of our own binary, created *inside* the
        // enabled window, so the kernel emits a real PERF_RECORD_MMAP2 we can
        // capture (pre-existing code is never re-emitted — see the header note).
        int exeFd = (() @trusted => open("/proc/self/exe", O_RDONLY))();

        ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_RESET, 0);
        ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_ENABLE, 0);
        void* exeMap = MAP_FAILED;
        if (exeFd >= 0)
            exeMap = (() @trusted => mmap(null, pageSize, PROT_READ | PROT_EXEC, MAP_PRIVATE, exeFd, 0))();
        workload();
        if (exeMap !is MAP_FAILED)
            (() @trusted => munmap(exeMap, pageSize))();
        if (exeFd >= 0)
            close(exeFd);
        ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_DISABLE, 0);

        // ---- drain the ring: data_tail .. data_head, wrapping mod dataSize
        // (the reader-side seqcount contract: acquire-load head, process, then
        //  release-store the new tail).
        const head = atomicLoad!(MemoryOrder.acq)(meta.data_head);
        ulong tail = meta.data_tail;

        Mapping[] maps;
        ulong[] ips;
        ulong lost = 0;
        ubyte[8192] rec;

        void ringCopy(ulong pos, ubyte* dst, size_t n) @trusted
        {
            const o = pos % dataSize;
            if (o + n <= dataSize)
                memcpy(dst, dataArea + o, n);
            else
            {
                const first = cast(size_t)(dataSize - o);
                memcpy(dst, dataArea + o, first);
                memcpy(dst + first, dataArea, n - first);
            }
        }

        while (tail < head)
        {
            perf_event_header h;
            ringCopy(tail, cast(ubyte*)&h, h.sizeof);
            if (h.size == 0)
                break;
            size_t sz = h.size;
            if (sz > rec.length)
                sz = rec.length;
            ringCopy(tail, rec.ptr, sz);
            tail += h.size;

            if (h.type == perf_event_type.PERF_RECORD_SAMPLE)
            {
                // body: ip(u64), pid(u32), tid(u32), time(u64)
                ips ~= *(() @trusted => cast(ulong*)(rec.ptr + 8))();
            }
            else if (h.type == perf_event_type.PERF_RECORD_MMAP2)
            {
                // body offsets (after 8-byte header): addr@16 len@24 pgoff@32
                // maj@40 min@44 ino@48 ino_gen@56 prot@64 flags@68 filename@72
                Mapping m;
                (() @trusted {
                    m.addr = *cast(ulong*)(rec.ptr + 16);
                    m.len = *cast(ulong*)(rec.ptr + 24);
                    m.pgoff = *cast(ulong*)(rec.ptr + 32);
                    m.prot = *cast(uint*)(rec.ptr + 64);
                    auto fn = cast(char*)(rec.ptr + 72);
                    m.filename = fromStringz(fn).idup;
                })();
                maps ~= m;
            }
            else if (h.type == perf_event_type.PERF_RECORD_LOST)
                lost += *(() @trusted => cast(ulong*)(rec.ptr + 8 + 8))(); // id(u64), lost(u64)
        }
        atomicStore!(MemoryOrder.rel)(meta.data_tail, head);

        (() @trusted => munmap(base, mmapSize))();
        close(fd);

        writefln("captured: %d PERF_RECORD_MMAP2 mappings, %d IP samples%s",
            maps.length, ips.length, lost ? " (" ~ "some LOST — ring overflow" ~ ")" : "");
        if (ips.length == 0)
        {
            writeln("note: no samples captured (workload too short, or overflow "
                ~ "interrupts denied) — nothing to symbolize, but the ring path ran");
            return 0;
        }

        // ---- symbolize via libdwfl: build the module model from the live
        //      process, then addr -> symbol -> line for each IP ------------
        __gshared DwflCallbacks cb;
        cb.find_elf = (() @trusted => cast(void*)&dwfl_linux_proc_find_elf)();
        cb.find_debuginfo = (() @trusted => cast(void*)&dwfl_standard_find_debuginfo)();
        cb.section_address = null;
        cb.debuginfo_path = null;

        Dwfl* dwfl = (() @trusted => dwfl_begin(&cb))();
        bool symbolized = false;
        int[string] symCount;
        string[string] symLine; // representative file:line per symbol
        ulong[string] symIp; // representative IP per symbol
        if (dwfl !is null)
        {
            const rc1 = (() @trusted => dwfl_linux_proc_report(dwfl, getpid()))();
            const rc2 = (() @trusted => dwfl_report_end(dwfl, null, null))();
            if (rc1 == 0 && rc2 == 0)
            {
                symbolized = true;
                foreach (ip; ips)
                {
                    auto mod = (() @trusted => dwfl_addrmodule(dwfl, ip))();
                    if (mod is null)
                    {
                        symCount["<no module>"]++;
                        continue;
                    }
                    GElf_Off off;
                    GElf_Sym sym;
                    const namez = (() @trusted => dwfl_module_addrinfo(
                        mod, ip, &off, &sym, null, null, null))();
                    string name = namez ? fromStringz(namez).idup : "<unknown>";
                    symCount[name]++;
                    if (name !in symIp)
                        symIp[name] = ip;
                    if (name !in symLine)
                    {
                        auto line = (() @trusted => dwfl_module_getsrc(mod, ip))();
                        if (line !is null)
                        {
                            int lineno;
                            auto srcz = (() @trusted => dwfl_lineinfo(
                                line, null, &lineno, null, null, null))();
                            if (srcz)
                            {
                                import std.path : baseName;
                                import std.conv : to;

                                symLine[name] = baseName(fromStringz(srcz).idup) ~ ":" ~ lineno.to!string;
                            }
                        }
                    }
                }
            }
        }

        if (!symbolized)
        {
            writeln("note: libdwfl unavailable/failed to report modules — "
                ~ "capture succeeded; symbolization skipped");
            (() @trusted { if (dwfl) dwfl_end(dwfl); })();
            return 0;
        }

        // Top symbols by sample count.
        import std.algorithm : sort;
        import std.array : array;

        auto rows = symCount.byKeyValue.array;
        rows.sort!((a, b) => a.value > b.value);
        writeln("top self-symbols (dwfl: name — samples — file:line):");
        size_t shown = 0;
        foreach (r; rows)
        {
            writefln("  %-28s %6d   %s", r.key, r.value,
                r.key in symLine ? symLine[r.key] : "(no DWARF line info)");
            if (++shown >= 8)
                break;
        }

        // ---- the captured PERF_RECORD_MMAP2 stream -----------------------
        import std.path : baseName;

        writefln("\nPERF_RECORD_MMAP2 captured during the window: %d record(s)", maps.length);
        foreach (ref m; maps)
            writefln("  [0x%x, 0x%x) pgoff=0x%x prot=0x%x %s",
                m.addr, m.addr + m.len, m.pgoff, m.prot, m.filename);
        writeln("  (the kernel re-emits MMAP2 only for mappings made while enabled; "
            ~ "pre-existing code is recovered from /proc/PID/maps — what dwfl reads.)");

        // Tie the two halves together: the deliberate exe mapping's filename is
        // the same binary libdwfl symbolized our functions against.
        string hot = rows[0].key;
        enum exeName = "cpu_pmu_sampling_symbolize"; // matches dub's `name`
        bool exeSeen = false;
        foreach (ref m; maps)
            if (m.filename.baseName == exeName)
            {
                exeSeen = true;
                break;
            }
        if (exeSeen && hot in symIp)
            writefln("model check: hottest symbol %s (IP 0x%x) was symbolized by libdwfl, "
                ~ "and a captured MMAP2 names the same image (%s).", hot, symIp[hot], exeName);
        else if (maps.length)
            writefln("model check: captured MMAP2 for %s; symbolization via /proc/self/maps.",
                maps[0].filename.baseName);
        else
            writeln("model check: no MMAP2 captured this window — symbolization still "
                ~ "succeeded via /proc/self/maps (the pre-existing-mapping path).");

        (() @trusted => dwfl_end(dwfl))();
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

        writefln("SKIP: perf_event sampling is Linux-only");
        return 0;
    }
}
