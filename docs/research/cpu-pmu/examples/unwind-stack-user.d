#!/usr/bin/env dub
/+ dub.sdl:
    name "cpu_pmu_unwind_stack_user"
    platforms "linux"
    libs "dw" "elf"
    dflags "-g" "--frame-pointer=none"
    targetPath "build"
+/
/**
 * DWARF-CFI stack unwinding from `PERF_SAMPLE_STACK_USER` + `PERF_SAMPLE_REGS_USER`
 * on a frame-pointer-less build — the "call-graph profiler" acquisition path.
 *
 * Frame-pointer omission (`--frame-pointer=none`) makes the classic `%rbp`
 * chain-walk impossible, so a backtrace must come from DWARF Call Frame
 * Information. We arm `cycles` sampling that, on each overflow, additionally
 * copies the interrupted thread's **register file** (`REGS_USER`) and a slab of
 * its **user stack** (`STACK_USER`) into the ring buffer. Offline, we feed those
 * to elfutils `libdwfl`'s frame API — `dwfl_attach_state` with a
 * `Dwfl_Thread_Callbacks` whose `memory_read` serves bytes from the captured
 * stack slab and whose `set_initial_registers` seeds the captured registers,
 * then `dwfl_getthread_frames` drives the CFI unwinder frame by frame
 * (`dwfl_frame_pc`) — exactly the wiring `perf`'s `unwind-libdw.c` uses.
 *
 * The probe has two guaranteed stages: (1) it demonstrably *captures* the
 * registers + stack (printing the register ABI, key registers, and stack
 * `dyn_size`); (2) it attempts the full in-process CFI unwind and prints the
 * recovered backtrace. If the unwind cannot complete in-process it degrades to
 * stage 1 and notes that the unwind API path is grounded by source-reading —
 * either way it exits 0.
 *
 * Companion to docs/research/cpu-pmu/linux-perf-events.md
 *   § "Stack unwinding: `STACK_USER` + `REGS_USER` and DWARF CFI" and
 *   docs/research/cpu-pmu/elfutils.md § "DWARF-CFI stack unwinding".
 *
 * Run with: nix shell nixpkgs#elfutils nixpkgs#pkg-config -c dub run --single unwind-stack-user.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX (Zen 4, x86-64),
 * `/proc/sys/kernel/perf_event_paranoid` = -1, elfutils 0.195 (libdw/libdwfl),
 * LDC 1.41 druntime `core.sys.linux.perf_event`. The perf→DWARF register
 * mapping below is x86-64-specific.
 *
 * Portability: any missing capability prints a `SKIP:` line and exits 0.
 */
module cpu_pmu_unwind_stack_user;

version (linux)
{
    version (X86_64) {}
    else
        version = NotX86_64;
}

version (linux)
version (X86_64)
{
    import core.sys.linux.perf_event;
    import core.sys.posix.unistd : close, getpid, sysconf, _SC_PAGESIZE;
    import core.sys.posix.sys.ioctl : ioctl;
    import core.sys.posix.sys.mman : mmap, munmap, PROT_READ, PROT_WRITE, MAP_SHARED, MAP_FAILED;
    import core.stdc.config : c_ulong;
    import core.stdc.string : memcpy;
    import core.atomic : atomicLoad, atomicStore, MemoryOrder;
    import core.time : MonoTime, msecs;
    import std.stdio : writefln, writeln;
    import std.string : fromStringz;

    // ---- elfutils libdwfl: extern(C) prototypes ------------------------
    alias Dwarf_Addr = ulong;
    alias Dwarf_Word = ulong;
    alias GElf_Addr = ulong;
    alias GElf_Off = ulong;
    alias GElf_Word = uint;

    struct GElf_Sym
    {
        uint st_name;
        ubyte st_info;
        ubyte st_other;
        ushort st_shndx;
        ulong st_value;
        ulong st_size;
    }

    struct Dwfl;
    struct Dwfl_Module;
    struct Dwfl_Frame;
    struct Dwfl_Thread;
    struct Elf;

    /// `Dwfl_Callbacks` (find_elf, find_debuginfo, section_address, debuginfo_path).
    struct DwflCallbacks
    {
        void* find_elf;
        void* find_debuginfo;
        void* section_address;
        char** debuginfo_path;
    }

    /// `Dwfl_Thread_Callbacks` (elfutils@6f8f78c libdwfl/libdwfl.h:661): field
    /// order next_thread, get_thread, memory_read, set_initial_registers,
    /// detach, thread_detach.
    struct DwflThreadCallbacks
    {
        void* next_thread;
        void* get_thread;
        void* memory_read;
        void* set_initial_registers;
        void* detach;
        void* thread_detach;
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
        bool dwfl_attach_state(Dwfl*, Elf*, int pid, const(DwflThreadCallbacks)*, void* arg);
        int dwfl_getthread_frames(Dwfl*, int tid, void* callback, void* arg);
        bool dwfl_frame_pc(Dwfl_Frame*, Dwarf_Addr* pc, bool* isactivation);
        void dwfl_thread_state_register_pc(Dwfl_Thread*, Dwarf_Word pc);
        bool dwfl_thread_state_registers(Dwfl_Thread*, int firstreg, uint nregs, const(Dwarf_Word)* regs);
        int dwfl_linux_proc_find_elf();
        int dwfl_standard_find_debuginfo();
    }

    // ---- perf x86-64 register order (arch/x86/include/uapi/asm/perf_regs.h)
    // The sample_regs_user mask we set selects, in ascending bit order:
    //   AX BX CX DX SI DI BP SP IP  (bits 0..8), then R8..R15 (bits 16..23).
    enum ulong regsMask = 0x1FFUL | (0xFFUL << 16); // 17 registers
    enum CapIdx { AX, BX, CX, DX, SI, DI, BP, SP, IP, R8, R9, R10, R11, R12, R13, R14, R15 }

    /// One captured sample: leaf IP, the 17 selected registers (perf order), and
    /// a copy of the user-stack slab (valid `dyn_size` bytes from `sp` upward).
    struct Sample
    {
        ulong ip;
        int tid;
        ulong regsAbi;
        ulong[17] regs;
        ubyte[] stack;
        ulong sp;
    }

    // The unwind callbacks are C function pointers; a single-threaded probe can
    // route their context through one global.
    __gshared Sample* gSample;
    __gshared Dwarf_Addr[64] gFrames;
    __gshared size_t gNFrames;

    extern (C) int uwNextThread(Dwfl* dwfl, void* arg, void** threadArgp) @nogc nothrow
    {
        if (*threadArgp !is null)
            return 0;
        *threadArgp = arg;
        return gSample.tid;
    }

    extern (C) bool uwMemoryRead(Dwfl* dwfl, Dwarf_Addr addr, Dwarf_Word* result, void* arg) @nogc nothrow
    {
        auto s = gSample;
        if (addr >= s.sp && addr + 8 <= s.sp + s.stack.length)
        {
            *result = *cast(ulong*)(s.stack.ptr + (addr - s.sp));
            return true;
        }
        return false; // outside the captured slab → unwinder stops here
    }

    extern (C) bool uwSetInitialRegisters(Dwfl_Thread* thread, void* arg) @nogc nothrow
    {
        auto s = gSample;
        // Map perf capture order → DWARF x86-64 register numbers 0..16.
        with (CapIdx)
        {
            Dwarf_Word[17] dw = [
                s.regs[AX], s.regs[DX], s.regs[CX], s.regs[BX], // dw 0..3
                s.regs[SI], s.regs[DI], s.regs[BP], s.regs[SP], // dw 4..7
                s.regs[R8], s.regs[R9], s.regs[R10], s.regs[R11], // dw 8..11
                s.regs[R12], s.regs[R13], s.regs[R14], s.regs[R15], // dw 12..15
                s.regs[IP], // dw 16 = RIP
            ];
            dwfl_thread_state_register_pc(thread, s.regs[IP]);
            return dwfl_thread_state_registers(thread, 0, 17, dw.ptr);
        }
    }

    extern (C) int uwFrameCb(Dwfl_Frame* state, void* arg) @nogc nothrow
    {
        Dwarf_Addr pc;
        bool isActivation;
        if (!dwfl_frame_pc(state, &pc, &isActivation))
            return 1; // DWARF_CB_ABORT
        if (!isActivation && pc)
            pc -= 1; // step back into the call instruction for the caller frames
        if (gNFrames < gFrames.length)
            gFrames[gNFrames++] = pc;
        return gNFrames >= 32 ? 1 : 0; // cap depth; DWARF_CB_OK = 0
    }

    // ---- a deliberately deep, frame-pointer-less call chain ------------
    __gshared ulong sink;

    pragma(inline, false) ulong level3(ulong x)
    {
        ulong s = 0;
        foreach (i; 0 .. 6000)
            s += (x ^ i) * (i + 1);
        return s;
    }

    pragma(inline, false) ulong level2(ulong x) => level3(x) + level3(x >> 1);
    pragma(inline, false) ulong level1(ulong x) => level2(x) ^ level2(x + 1);

    void workload()
    {
        auto deadline = MonoTime.currTime + 400.msecs;
        ulong acc = 0xABCD_1234_5678_9EF0UL;
        while (MonoTime.currTime < deadline)
            acc += level1(acc);
        sink += acc;
    }

    /// Resolve a PC to `name+off` for the backtrace print.
    string symbolize(Dwfl* dwfl, ulong pc)
    {
        auto mod = (() @trusted => dwfl_addrmodule(dwfl, pc))();
        if (mod is null)
            return "<no module>";
        GElf_Off off;
        GElf_Sym sym;
        const namez = (() @trusted => dwfl_module_addrinfo(mod, pc, &off, &sym, null, null, null))();
        if (namez is null)
            return "<unknown>";
        import std.conv : to;

        return fromStringz(namez).idup ~ "+0x" ~ off.to!string(16);
    }

    int run()
    {
        const pageSize = cast(size_t) sysconf(_SC_PAGESIZE);
        enum dataPages = 256;
        const dataSize = dataPages * pageSize;
        const mmapSize = (1 + dataPages) * pageSize;
        enum stackBytes = 8192u;

        perf_event_attr attr;
        attr.size = perf_event_attr.sizeof;
        attr.type = perf_type_id.PERF_TYPE_HARDWARE;
        attr.config = perf_hw_id.PERF_COUNT_HW_CPU_CYCLES;
        attr.sample_type = perf_event_sample_format.PERF_SAMPLE_IP
            | perf_event_sample_format.PERF_SAMPLE_TID
            | perf_event_sample_format.PERF_SAMPLE_TIME
            | perf_event_sample_format.PERF_SAMPLE_REGS_USER
            | perf_event_sample_format.PERF_SAMPLE_STACK_USER;
        attr.sample_regs_user = regsMask;
        attr.sample_stack_user = stackBytes;
        attr.freq = 1;
        attr.sample_freq = 1500;
        attr.disabled = 1;
        attr.exclude_kernel = 1;
        attr.exclude_hv = 1;

        int fd = (() @trusted => cast(int) perf_event_open(&attr, 0, -1, -1, 0))();
        if (fd < 0)
        {
            writefln("SKIP: perf_event_open (stack sampling) failed — "
                ~ "perf_event_paranoid, seccomp, or no PMU");
            return 0;
        }

        void* base = (() @trusted => mmap(null, mmapSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0))();
        if (base is MAP_FAILED)
        {
            writefln("SKIP: mmap of perf ring buffer failed");
            close(fd);
            return 0;
        }
        auto meta = cast(perf_event_mmap_page*) base;
        auto dataArea = cast(ubyte*) base + pageSize;

        ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_RESET, 0);
        ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_ENABLE, 0);
        workload();
        ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_DISABLE, 0);

        const head = atomicLoad!(MemoryOrder.acq)(meta.data_head);
        ulong tail = meta.data_tail;
        ubyte[32768] rec;

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

        Sample[] samples;
        size_t nRegsAbiNone = 0;
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
            if (h.type != perf_event_type.PERF_RECORD_SAMPLE)
                continue;

            // body: ip(8) pid(4) tid(4) time(8) regsAbi(8) regs[17*8]
            //       stackSize(8) stackData[stackSize] dynSize(8)
            (() @trusted {
                size_t o = 8;
                Sample s;
                s.ip = *cast(ulong*)(rec.ptr + o); o += 8;
                o += 4; // pid
                s.tid = *cast(int*)(rec.ptr + o); o += 4;
                o += 8; // time
                s.regsAbi = *cast(ulong*)(rec.ptr + o); o += 8;
                if (s.regsAbi == 0)
                {
                    nRegsAbiNone++;
                    return;
                }
                memcpy(s.regs.ptr, rec.ptr + o, 17 * 8); o += 17 * 8;
                const stackSize = *cast(ulong*)(rec.ptr + o); o += 8;
                const dynSize = *cast(ulong*)(rec.ptr + o + stackSize);
                s.sp = s.regs[CapIdx.SP];
                const valid = dynSize < stackSize ? dynSize : stackSize;
                s.stack = (rec.ptr + o)[0 .. cast(size_t) valid].dup;
                samples ~= s;
            })();
        }
        atomicStore!(MemoryOrder.rel)(meta.data_tail, head);
        (() @trusted => munmap(base, mmapSize))();
        close(fd);

        writefln("captured: %d samples with REGS_USER+STACK_USER "
            ~ "(%d had ABI_NONE, no user regs)", samples.length, nRegsAbiNone);
        if (samples.length == 0)
        {
            writeln("note: no register/stack samples captured — the ring path ran; "
                ~ "nothing to unwind");
            return 0;
        }

        // ---- set up libdwfl module model ---------------------------------
        __gshared DwflCallbacks cb;
        cb.find_elf = (() @trusted => cast(void*)&dwfl_linux_proc_find_elf)();
        cb.find_debuginfo = (() @trusted => cast(void*)&dwfl_standard_find_debuginfo)();
        Dwfl* dwfl = (() @trusted => dwfl_begin(&cb))();
        if (dwfl is null
            || (() @trusted => dwfl_linux_proc_report(dwfl, getpid()))() != 0
            || (() @trusted => dwfl_report_end(dwfl, null, null))() != 0)
        {
            writeln("note: libdwfl module reporting failed — capture verified; "
                ~ "unwind skipped");
            return 0;
        }

        // Pick a sample whose leaf IP lands in level3 (the deepest frame) so the
        // backtrace is a stable demonstration; fall back to the first sample.
        Sample* chosen = &samples[0];
        foreach (ref s; samples)
        {
            auto nm = symbolize(dwfl, s.ip);
            import std.algorithm : canFind;

            if (nm.canFind("level3"))
            {
                chosen = &s;
                break;
            }
        }

        // ---- Stage 1: prove the capture (registers + stack) ---------------
        with (CapIdx)
            writefln("\nchosen sample: leaf IP 0x%x (%s)\n"
                ~ "  regs ABI=%d  RIP=0x%x  RSP=0x%x  RBP=0x%x  captured stack=%d bytes",
                chosen.ip, symbolize(dwfl, chosen.ip), chosen.regsAbi,
                chosen.regs[IP], chosen.regs[SP], chosen.regs[BP], chosen.stack.length);

        // ---- Stage 2: attempt the full in-process CFI unwind --------------
        gSample = chosen;
        gNFrames = 0;
        __gshared DwflThreadCallbacks tcb;
        tcb.next_thread = (() @trusted => cast(void*)&uwNextThread)();
        tcb.memory_read = (() @trusted => cast(void*)&uwMemoryRead)();
        tcb.set_initial_registers = (() @trusted => cast(void*)&uwSetInitialRegisters)();

        const attached = (() @trusted => dwfl_attach_state(dwfl, null, chosen.tid, &tcb, null))();
        int rc = -1;
        if (attached)
            rc = (() @trusted => dwfl_getthread_frames(dwfl, gSample.tid,
                (() @trusted => cast(void*)&uwFrameCb)(), null))();

        if (attached && gNFrames > 0)
        {
            writefln("\nDWARF-CFI backtrace (%d frames, frame pointers OMITTED — "
                ~ "so this came purely from .eh_frame/.debug_frame CFI):", gNFrames);
            foreach (i, pc; gFrames[0 .. gNFrames])
                writefln("  #%-2d 0x%x  %s", i, pc, symbolize(dwfl, pc));
            writeln("  (dwfl_getthread_frames drove the unwind; memory_read served "
                ~ "the captured STACK_USER slab, set_initial_registers the REGS_USER set.)");
        }
        else
        {
            writefln("\nnote: in-process dwfl unwind did not complete "
                ~ "(attach=%s, rc=%d) — the CAPTURE is verified above; the unwind API "
                ~ "path (dwfl_attach_state → Dwfl_Thread_Callbacks → "
                ~ "dwfl_getthread_frames → dwfl_frame_pc) is grounded in "
                ~ "docs/research/cpu-pmu/elfutils.md by source-reading.", attached, rc);
        }

        (() @trusted => dwfl_end(dwfl))();
        return 0;
    }
}

int main()
{
    version (linux)
    {
        version (X86_64)
            return run();
        else
        {
            import std.stdio : writefln;

            writefln("SKIP: this unwind probe's perf→DWARF register map is x86-64-only");
            return 0;
        }
    }
    else
    {
        import std.stdio : writefln;

        writefln("SKIP: perf_event sampling is Linux-only");
        return 0;
    }
}
