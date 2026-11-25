#!/usr/bin/env dub
/+ dub.sdl:
    name "fitbench"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    buildType "bench" {
        buildOptions "releaseMode" "optimize" "inline" "noBoundsCheck"
        dflags "-O3" "-mcpu=native" platform="ldc"
    }
+/
/**
 * Fused vs separate intrinsic ("fit") sizing for an immediate-mode UI
 * layout, Clay-style. See README.md.
 *
 * Variants (all end-to-end: build + fit):
 *   fused-aos  fit accumulated on a stack while building, written at close
 *   sep-aos    build, then reverse pre-order sweep over the fat records
 *   sep-soa    build into hot SoA arrays + cold payload, reverse sweep on SoA
 *   fused-soa  fused accumulation, writes into SoA arrays
 *   level-soa  sep-soa build (+depth byte), then counting-sort by depth so
 *              siblings are contiguous, vectorised per-parent sum/max,
 *              bottom-up by level, scatter back
 * Plus rest-aos / rest-soa: Clay-style grow along x, grow along y, positions.
 */
module fitbench;

import core.stdc.stdlib : malloc, free, exit;
import core.stdc.string : memset;
import core.time : MonoTime;
import std.algorithm : sort, max, min, canFind;
import std.conv : to;
import std.math : pow, ceil;
import std.random : Random, uniform, uniform01;
import std.stdio : writefln, writeln, stdout, stderr;
import std.string : split;

version (LDC) import ldc.attributes : fastmath;
else struct fastmath {}

// ---------------------------------------------------------------------------
// Event stream: what "user UI code" does, replayed identically by every variant
// ---------------------------------------------------------------------------

enum : ubyte { OpOpen = 0, OpLabel = 1, OpClose = 2 }
enum : ubyte { GrowX = 1, GrowY = 2 }

struct Ev
{
    ubyte op, axis, grow, pad; // pad: per side
    ushort gap, textLen;
    uint textOff;
}
static assert(Ev.sizeof == 12);

enum poolLen = 1 << 16;
enum glyphW = 8.0f, lineH = 16.0f;

struct Gen
{
    Ev[] evs;
    Random rng;
    int nodes;
    int maxDepth;
    int depth;
    int maxFan;

    void open(ubyte axis, ubyte grow, ubyte pad, ushort gap)
    {
        evs ~= Ev(OpOpen, axis, grow, pad, gap, 0, 0);
        ++nodes;
        ++depth;
        maxDepth = max(maxDepth, depth);
    }

    void close()
    {
        evs ~= Ev(OpClose);
        --depth;
    }

    void label(ubyte grow = 0)
    {
        ushort len = cast(ushort) uniform(3, 31, rng);
        evs ~= Ev(OpLabel, 0, grow, 0, 0, len, uniform(0u, cast(uint)(poolLen - 32), rng));
        ++nodes;
        maxDepth = max(maxDepth, depth + 1);
    }
}

/// root col > panel col > (header row(label,label), scroll col > rows(label, label*, label))
Gen genList(int n)
{
    Gen g;
    g.rng = Random(42);
    g.open(1, 0, 0, 0); // root column
    g.open(1, GrowX | GrowY, 8, 4); // panel
    g.open(0, GrowX, 4, 8); // header
    g.label();
    g.label(GrowX);
    g.close();
    g.open(1, GrowX | GrowY, 0, 2); // scroll column
    int rows = (n - 6) / 4;
    g.maxFan = rows;
    foreach (r; 0 .. rows)
    {
        g.open(0, GrowX, 4, 8);
        g.label();
        g.label(GrowX);
        g.label();
        g.close();
    }
    g.close();
    g.close();
    g.close();
    return g;
}

/// Balanced-ish nested panels: fan-out mostly 2..8, sometimes a 50..1000 list,
/// depth <= 12, exactly n nodes.
Gen genPanels(int n)
{
    Gen g;
    g.rng = Random(7);
    enum maxD = 12;
    void node(int budget, int depth)
    {
        if (budget == 1)
        {
            g.label(uniform(0, 8, g.rng) == 0 ? GrowX : 0);
            return;
        }
        ubyte axis = cast(ubyte)((depth & 1) ^ (uniform(0, 4, g.rng) == 0));
        ubyte grow = cast(ubyte) uniform(0, 4, g.rng);
        g.open(axis, grow, cast(ubyte) uniform(0, 9, g.rng), cast(ushort) uniform(0, 9, g.rng));
        int rem = budget - 1;
        int f;
        if (rem <= 8 || depth >= maxD - 2)
            f = rem;
        else
        {
            f = uniform(2, 9, g.rng);
            if (rem >= 100 && uniform(0, 10, g.rng) == 0)
                f = uniform(50, min(1000, rem) + 1, g.rng);
            int levels = maxD - 2 - depth;
            int minF = cast(int) ceil(pow(cast(double) rem, 1.0 / levels));
            f = min(max(f, minF), rem);
        }
        g.maxFan = max(g.maxFan, f);
        // split rem into f positive parts with skewed random weights
        auto w = new double[f];
        double W = 0;
        foreach (ref x; w)
        {
            double u = uniform01(g.rng);
            x = u * u * u;
            W += x;
        }
        int left = rem - f;
        foreach (k; 0 .. f)
        {
            int extra = k + 1 == f ? left : cast(int)((rem - f) * w[k] / W);
            extra = min(extra, left);
            left -= extra;
            node(1 + extra, depth + 1);
        }
        g.close();
    }

    node(n, 0);
    return g;
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

/// The fat AoS widget record; the first 64 bytes are the layout-relevant head.
struct Node(size_t SIZE)
{
    int parent;
    ubyte kind, axis, grow, _r;
    int childCount;
    int growCount;
    float gap = 0;
    float[2] pad = 0; // total padding per axis (left+right, top+bottom)
    uint textLen;
    float[2] sz = 0;
    float[2] fit = 0;
    float[2] pos = 0;
    const(char)* text;
    static if (SIZE > 64)
        ubyte[SIZE - 64] payload;
}

static assert(Node!64.sizeof == 64 && Node!128.sizeof == 128 && Node!328.sizeof == 328);

/// SoA variant's cold payload: text slice + id + the same fat payload.
struct Cold(size_t SIZE)
{
    const(char)* text;
    uint textLen;
    uint id;
    static if (SIZE > 64)
        ubyte[SIZE - 64] payload;
}

struct Soa(size_t SIZE)
{
    int* parent;
    ubyte* flags; // axis | grow << 1
    int* childCount;
    int* growCount;
    float* gap;
    float[2]* pad;
    float[2]* sz;
    float[2]* fit;
    float[2]* pos;
    ubyte* depth;
    Cold!SIZE* cold;

    void alloc(size_t n)
    {
        parent = cast(int*) malloc(n * 4);
        flags = cast(ubyte*) malloc(n);
        childCount = cast(int*) malloc(n * 4);
        growCount = cast(int*) malloc(n * 4);
        gap = cast(float*) malloc(n * 4);
        pad = cast(float[2]*) malloc(n * 8);
        sz = cast(float[2]*) malloc(n * 8);
        fit = cast(float[2]*) malloc(n * 8);
        pos = cast(float[2]*) malloc(n * 8);
        depth = cast(ubyte*) malloc(n);
        cold = cast(Cold!SIZE*) malloc(n * Cold!SIZE.sizeof);
    }

    void release()
    {
        foreach (p; [cast(void*) parent, flags, childCount, growCount, gap, pad, sz, fit, pos, depth, cold])
            free(p);
    }
}

/// Scratch for the level-order variant.
struct LevelScratch
{
    int* ord;
    float* w, h;
    float* padM, padC; // main/cross padding of the node itself
    float* gap;
    int* cnt;
    ubyte* axis;

    void alloc(size_t n)
    {
        ord = cast(int*) malloc(n * 4);
        w = cast(float*) malloc(n * 4);
        h = cast(float*) malloc(n * 4);
        padM = cast(float*) malloc(n * 4);
        padC = cast(float*) malloc(n * 4);
        gap = cast(float*) malloc(n * 4);
        cnt = cast(int*) malloc(n * 4);
        axis = cast(ubyte*) malloc(n);
    }

    void release()
    {
        foreach (p; [cast(void*) ord, w, h, padM, padC, gap, cnt, axis])
            free(p);
    }
}

// ---------------------------------------------------------------------------
// Build (+ fused fit)
// ---------------------------------------------------------------------------

struct Frame
{
    int idx;
    int count;
    int growCount;
    int axis;
    float sum = 0; // main-axis sum of children
    float mx = 0; // cross-axis max of children
}

pragma(inline, true) void contribute(ref Frame f, float w, float h)
{
    float m = f.axis ? h : w;
    float c = f.axis ? w : h;
    f.sum += m;
    f.mx = c > f.mx ? c : f.mx;
}

pragma(inline, true) void writePayload(P)(ref P payload, int i)
{
    // a few non-zero fields a widget would set: id hash, style ref, colour
    static if (P.sizeof >= 16)
    {
        ulong id = (cast(ulong) i * 0x9E3779B97F4A7C15UL) ^ 0xABCDEF;
        *cast(ulong*)&payload[0] = id;
        *cast(uint*)&payload[8] = 0xFF336699;
        *cast(uint*)&payload[12] = cast(uint) i;
    }
}

int buildAos(bool fused, size_t S)(const(Ev)[] evs, const(char)* pool, Node!S* nodes)
{
    Frame[64] st = void;
    int sp = 0, n = 0;
    foreach (ref const e; evs)
    {
        if (e.op == OpClose)
        {
            Frame f = st[--sp];
            auto nd = &nodes[f.idx];
            nd.childCount = f.count;
            nd.growCount = f.growCount;
            static if (fused)
            {
                int a = f.axis;
                float m = f.sum + nd.pad[a] + nd.gap * (f.count > 0 ? f.count - 1 : 0);
                float c = f.mx + nd.pad[1 - a];
                float w = a ? c : m, h = a ? m : c;
                nd.sz[0] = w;
                nd.sz[1] = h;
                if (sp)
                    contribute(st[sp - 1], w, h);
            }
        }
        else
        {
            int i = n++;
            auto nd = &nodes[i];
            *nd = Node!S.init;
            nd.parent = sp ? st[sp - 1].idx : -1;
            nd.kind = e.op;
            nd.axis = e.axis;
            nd.grow = e.grow;
            nd.gap = e.gap;
            nd.pad[0] = nd.pad[1] = 2.0f * e.pad;
            nd.text = pool + e.textOff;
            nd.textLen = e.textLen;
            static if (S > 64)
                writePayload(nd.payload, i);
            if (sp)
            {
                st[sp - 1].count++;
                st[sp - 1].growCount += (e.grow >> st[sp - 1].axis) & 1;
            }
            if (e.op == OpLabel)
            {
                float w = e.textLen * glyphW; // cached measure
                nd.sz[0] = w;
                nd.sz[1] = lineH;
                static if (fused)
                    contribute(st[sp - 1], w, lineH);
            }
            else
                st[sp++] = Frame(i, 0, 0, e.axis);
        }
    }
    return n;
}

int buildSoa(bool fused, bool withDepth, size_t S)(const(Ev)[] evs, const(char)* pool, ref Soa!S s)
{
    Frame[64] st = void;
    int sp = 0, n = 0;
    foreach (ref const e; evs)
    {
        if (e.op == OpClose)
        {
            Frame f = st[--sp];
            s.childCount[f.idx] = f.count;
            s.growCount[f.idx] = f.growCount;
            static if (fused)
            {
                int a = f.axis;
                auto pd = s.pad[f.idx];
                float m = f.sum + pd[a] + s.gap[f.idx] * (f.count > 0 ? f.count - 1 : 0);
                float c = f.mx + pd[1 - a];
                float w = a ? c : m, h = a ? m : c;
                s.sz[f.idx][0] = w;
                s.sz[f.idx][1] = h;
                if (sp)
                    contribute(st[sp - 1], w, h);
            }
        }
        else
        {
            int i = n++;
            s.parent[i] = sp ? st[sp - 1].idx : -1;
            s.flags[i] = cast(ubyte)(e.axis | (e.grow << 1));
            s.gap[i] = e.gap;
            s.pad[i][0] = s.pad[i][1] = 2.0f * e.pad;
            s.childCount[i] = 0;
            s.growCount[i] = 0;
            static if (withDepth)
                s.depth[i] = cast(ubyte) sp;
            auto c = &s.cold[i];
            *c = Cold!S.init;
            c.text = pool + e.textOff;
            c.textLen = e.textLen;
            c.id = i;
            static if (S > 64)
                writePayload(c.payload, i);
            if (sp)
            {
                st[sp - 1].count++;
                st[sp - 1].growCount += (e.grow >> st[sp - 1].axis) & 1;
            }
            if (e.op == OpLabel)
            {
                float w = e.textLen * glyphW;
                s.sz[i][0] = w;
                s.sz[i][1] = lineH;
                static if (fused)
                    contribute(st[sp - 1], w, lineH);
            }
            else
            {
                s.sz[i][0] = s.sz[i][1] = 0;
                st[sp++] = Frame(i, 0, 0, e.axis);
            }
        }
    }
    return n;
}

// ---------------------------------------------------------------------------
// Separate fit passes
// ---------------------------------------------------------------------------

void fitSweepAos(size_t S)(Node!S* nodes, int n)
{
    for (int i = n - 1; i >= 0; --i)
    {
        auto nd = &nodes[i];
        int a = nd.axis;
        int c = nd.childCount;
        float w = nd.sz[0], h = nd.sz[1];
        float m = (a ? h : w) + nd.pad[a] + nd.gap * (c > 0 ? c - 1 : 0);
        float x = (a ? w : h) + nd.pad[1 - a];
        w = a ? x : m;
        h = a ? m : x;
        nd.sz[0] = w;
        nd.sz[1] = h;
        int p = nd.parent;
        if (p >= 0)
        {
            auto pn = &nodes[p];
            if (pn.axis == 0)
            {
                pn.sz[0] += w;
                pn.sz[1] = h > pn.sz[1] ? h : pn.sz[1];
            }
            else
            {
                pn.sz[1] += h;
                pn.sz[0] = w > pn.sz[0] ? w : pn.sz[0];
            }
        }
    }
}

void fitSweepSoa(size_t S)(ref Soa!S s, int n)
{
    auto sz = s.sz, pad = s.pad, gap = s.gap, cc = s.childCount, fl = s.flags, par = s.parent;
    for (int i = n - 1; i >= 0; --i)
    {
        int a = fl[i] & 1;
        int c = cc[i];
        float w = sz[i][0], h = sz[i][1];
        float m = (a ? h : w) + pad[i][a] + gap[i] * (c > 0 ? c - 1 : 0);
        float x = (a ? w : h) + pad[i][1 - a];
        w = a ? x : m;
        h = a ? m : x;
        sz[i][0] = w;
        sz[i][1] = h;
        int p = par[i];
        if (p >= 0)
        {
            if ((fl[p] & 1) == 0)
            {
                sz[p][0] += w;
                sz[p][1] = h > sz[p][1] ? h : sz[p][1];
            }
            else
            {
                sz[p][1] += h;
                sz[p][0] = w > sz[p][0] ? w : sz[p][0];
            }
        }
    }
}

/// sep-soa with the current parent's accumulator carried in registers while
/// consecutive (reverse pre-order) nodes share a parent, so sibling runs do
/// not form a store->load chain through sz[p]. Same op order => same bits.
void fitSweepSoaRc(size_t S)(ref Soa!S s, int n)
{
    auto sz = s.sz, pad = s.pad, gap = s.gap, cc = s.childCount, fl = s.flags, par = s.parent;
    int cur = -1, ca = 0;
    float am = 0, ac = 0;
    for (int i = n - 1; i >= 0; --i)
    {
        if (i == cur) // about to finalise the parent held in registers
        {
            sz[cur][ca] = am;
            sz[cur][1 - ca] = ac;
            cur = -1;
        }
        int a = fl[i] & 1;
        int c = cc[i];
        float w = sz[i][0], h = sz[i][1];
        float m = (a ? h : w) + pad[i][a] + gap[i] * (c > 0 ? c - 1 : 0);
        float x = (a ? w : h) + pad[i][1 - a];
        w = a ? x : m;
        h = a ? m : x;
        sz[i][0] = w;
        sz[i][1] = h;
        int p = par[i];
        if (p < 0)
            continue;
        if (p != cur)
        {
            if (cur >= 0)
            {
                sz[cur][ca] = am;
                sz[cur][1 - ca] = ac;
            }
            cur = p;
            ca = fl[p] & 1;
            am = sz[p][ca];
            ac = sz[p][1 - ca];
        }
        float pm = ca ? h : w, pc = ca ? w : h;
        am += pm;
        ac = pc > ac ? pc : ac;
    }
    if (cur >= 0)
    {
        sz[cur][ca] = am;
        sz[cur][1 - ca] = ac;
    }
}

@fastmath float sumRange(const(float)* p, int k)
{
    float s = 0;
    foreach (j; 0 .. k)
        s += p[j];
    return s;
}

@fastmath float maxRange(const(float)* p, int k)
{
    float m = 0;
    foreach (j; 0 .. k)
        m = p[j] > m ? p[j] : m;
    return m;
}

/// Returns ns spent in the pure level reduction (for the breakdown).
long fitLevel(size_t S)(ref Soa!S s, ref LevelScratch L, int n)
{
    // 1. counting sort by depth (stable => siblings contiguous within a level)
    int[66] start = 0;
    foreach (i; 0 .. n)
        start[s.depth[i] + 1]++;
    int maxD = 0;
    foreach (d; 1 .. 65)
    {
        if (start[d])
            maxD = d;
        start[d] += start[d - 1];
    }
    int[65] cur = start[0 .. 65];
    foreach (i; 0 .. n)
    {
        int j = cur[s.depth[i]]++;
        L.ord[j] = i;
        int a = s.flags[i] & 1;
        L.axis[j] = cast(ubyte) a;
        L.w[j] = s.sz[i][0];
        L.h[j] = s.sz[i][1];
        L.padM[j] = s.pad[i][a];
        L.padC[j] = s.pad[i][1 - a];
        L.gap[j] = s.gap[i];
        L.cnt[j] = s.childCount[i];
    }
    auto t0 = MonoTime.currTime;
    // 2. bottom-up, one level at a time; each parent's children are a contiguous run
    for (int d = maxD - 1; d >= 0; --d)
    {
        int c = start[d + 1];
        foreach (j; start[d] .. start[d + 1])
        {
            int k = L.cnt[j];
            if (k == 0)
                continue;
            float sw = L.axis[j] ? maxRange(L.w + c, k) : sumRange(L.w + c, k);
            float sh = L.axis[j] ? sumRange(L.h + c, k) : maxRange(L.h + c, k);
            float g = L.gap[j] * (k - 1);
            if (L.axis[j])
            {
                L.w[j] = sw + L.padC[j];
                L.h[j] = sh + L.padM[j] + g;
            }
            else
            {
                L.w[j] = sw + L.padM[j] + g;
                L.h[j] = sh + L.padC[j];
            }
            c += k;
        }
    }
    auto t1 = MonoTime.currTime;
    // 3. scatter back into pre-order
    foreach (j; 0 .. n)
    {
        int i = L.ord[j];
        s.sz[i][0] = L.w[j];
        s.sz[i][1] = L.h[j];
    }
    return (t1 - t0).total!"nsecs";
}

// ---------------------------------------------------------------------------
// Rest of a Clay-style layout (simplified): grow x, grow y, positions
// ---------------------------------------------------------------------------

enum float[2] rootSize = [1920.0f, 1080.0f];

void growAos(int ax, size_t S)(Node!S* nd, int n)
{
    nd[0].fit[ax] = nd[0].sz[ax];
    nd[0].sz[ax] = rootSize[ax];
    foreach (i; 1 .. n)
    {
        auto c = &nd[i];
        auto p = &nd[c.parent];
        c.fit[ax] = c.sz[ax];
        if ((c.grow >> ax) & 1)
        {
            if (p.axis == ax)
            {
                float extra = (p.sz[ax] - p.fit[ax]) / p.growCount;
                float v = c.sz[ax] + extra;
                c.sz[ax] = v > 0 ? v : 0;
            }
            else
                c.sz[ax] = p.sz[ax] - p.pad[ax];
        }
    }
}

void positionsAos(size_t S)(Node!S* nd, int n, float* cursor)
{
    nd[0].pos[0] = nd[0].pos[1] = 0;
    cursor[0] = 0;
    foreach (i; 1 .. n)
    {
        auto c = &nd[i];
        int pi = c.parent;
        auto p = &nd[pi];
        int a = p.axis;
        c.pos[a] = p.pos[a] + p.pad[a] * 0.5f + cursor[pi];
        c.pos[1 - a] = p.pos[1 - a] + p.pad[1 - a] * 0.5f;
        cursor[pi] += c.sz[a] + p.gap;
        cursor[i] = 0;
    }
}

void growSoa(int ax, size_t S)(ref Soa!S s, int n)
{
    auto sz = s.sz, fit = s.fit, fl = s.flags, par = s.parent, gc = s.growCount, pad = s.pad;
    fit[0][ax] = sz[0][ax];
    sz[0][ax] = rootSize[ax];
    foreach (i; 1 .. n)
    {
        int p = par[i];
        fit[i][ax] = sz[i][ax];
        if ((fl[i] >> (1 + ax)) & 1)
        {
            if ((fl[p] & 1) == ax)
            {
                float extra = (sz[p][ax] - fit[p][ax]) / gc[p];
                float v = sz[i][ax] + extra;
                sz[i][ax] = v > 0 ? v : 0;
            }
            else
                sz[i][ax] = sz[p][ax] - pad[p][ax];
        }
    }
}

void positionsSoa(size_t S)(ref Soa!S s, int n, float* cursor)
{
    auto sz = s.sz, pos = s.pos, fl = s.flags, par = s.parent, pad = s.pad, gap = s.gap;
    pos[0][0] = pos[0][1] = 0;
    cursor[0] = 0;
    foreach (i; 1 .. n)
    {
        int p = par[i];
        int a = fl[p] & 1;
        pos[i][a] = pos[p][a] + pad[p][a] * 0.5f + cursor[p];
        pos[i][1 - a] = pos[p][1 - a] + pad[p][1 - a] * 0.5f;
        cursor[p] += sz[i][a] + gap[p];
        cursor[i] = 0;
    }
}

// ---------------------------------------------------------------------------
// Checksums
// ---------------------------------------------------------------------------

ulong mix(ulong h, float f) => (h ^ *cast(uint*)&f) * 0x100000001b3UL;

ulong sumAos(size_t S)(Node!S* nd, int n, bool withPos)
{
    ulong h = 0xcbf29ce484222325UL;
    foreach (i; 0 .. n)
    {
        h = mix(mix(h, nd[i].sz[0]), nd[i].sz[1]);
        if (withPos)
            h = mix(mix(h, nd[i].pos[0]), nd[i].pos[1]);
    }
    return h;
}

ulong sumSoa(size_t S)(ref Soa!S s, int n, bool withPos)
{
    ulong h = 0xcbf29ce484222325UL;
    foreach (i; 0 .. n)
    {
        h = mix(mix(h, s.sz[i][0]), s.sz[i][1]);
        if (withPos)
            h = mix(mix(h, s.pos[i][0]), s.pos[i][1]);
    }
    return h;
}

// ---------------------------------------------------------------------------
// perf_event_open counters (in-process, around the timed region only)
// ---------------------------------------------------------------------------

extern (C) long syscall(long, ...) nothrow @nogc;
extern (C) int ioctl(int, ulong, ...) nothrow @nogc;
import core.sys.posix.unistd : read, close;

struct PerfAttr
{
    uint type, size;
    ulong config, samplePeriod, sampleType, readFormat, flags;
    uint wakeup, bpType;
    ulong config1;
}

static assert(PerfAttr.sizeof == 64);

enum nCtr = 5;
// cycles, instructions, L1D read misses, L2 misses (generic cache-misses; on
// Zen = l2_cache_req_stat.ic_dc_miss_in_l2), DRAM fills (raw
// ls_any_fills_from_sys.dram_io_all, event 0x44 umask 0x48; includes prefetch fills)
immutable uint[nCtr] ctrTypes = [0, 0, 3, 0, 4];
immutable ulong[nCtr] ctrCfgs = [0, 1, 0 | (0 << 8) | (1 << 16), 3, 0x4844];

struct Perf
{
    int leader = -1;
    int[nCtr] slot = -1; // position in group read
    int nOpen;

    void open()
    {
        foreach (k; 0 .. nCtr)
        {
            PerfAttr a;
            a.type = ctrTypes[k];
            a.size = PerfAttr.sizeof;
            a.config = ctrCfgs[k];
            a.readFormat = 8 | 1 | 2; // GROUP | TIME_ENABLED | TIME_RUNNING
            a.flags = (leader < 0 ? 1 : 0) | (1 << 5) | (1 << 6); // disabled(leader), excl kernel, hv
            int f = cast(int) syscall(298, &a, 0, -1, leader, 0UL);
            if (f < 0)
                continue;
            if (leader < 0)
                leader = f;
            slot[k] = nOpen++;
        }
    }

    void start()
    {
        if (leader < 0)
            return;
        ioctl(leader, 0x2403, 1); // RESET, group
        ioctl(leader, 0x2400, 1); // ENABLE, group
    }

    void stop()
    {
        if (leader >= 0)
            ioctl(leader, 0x2401, 1);
    }

    /// Reads the running group; returns false if multiplexed.
    bool snap(ref ulong[nCtr] out_)
    {
        out_[] = 0;
        if (leader < 0)
            return false;
        ulong[3 + nCtr] buf;
        if (read(leader, buf.ptr, buf.sizeof) <= 0)
            return false;
        foreach (k; 0 .. nCtr)
            if (slot[k] >= 0)
                out_[k] = buf[3 + slot[k]];
        return buf[1] == buf[2];
    }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

struct Result
{
    string variant;
    double total, build, pass, aux; // medians, ns/node
    double[nCtr] ctr; // medians, per node, whole timed region
    double[nCtr] passCtr; // medians, per node, pass only
    ulong checksum;
}

double median(double[] xs)
{
    sort(xs);
    return xs.length % 2 ? xs[$ / 2] : (xs[$ / 2 - 1] + xs[$ / 2]) / 2;
}

int reps = 21;
enum warmup = 3;
Perf perf;
ulong[nCtr][3] snaps;
bool[3] marked;
bool multiplexed;

/// Snapshot counters at phase boundary k (0 = start, 1 = build done, 2 = pass done).
/// Called outside the MonoTime-timed intervals.
void mark(int k)
{
    if (!perf.snap(snaps[k]))
        multiplexed = perf.leader >= 0;
    marked[k] = true;
}

Result measure(string name, int n, scope void delegate(out long, out long, out long) run, scope ulong delegate() check)
{
    double[] tot, bld, pas, aux;
    double[][nCtr] cs, ps;
    foreach (r; 0 .. warmup + reps)
    {
        long b, p, x;
        marked[] = false;
        perf.start();
        run(b, p, x);
        perf.stop();
        if (!marked[2])
            snaps[2] = snaps[1];
        if (r < warmup)
            continue;
        tot ~= cast(double)(b + p) / n;
        bld ~= cast(double) b / n;
        pas ~= cast(double) p / n;
        aux ~= cast(double) x / n;
        foreach (k; 0 .. nCtr)
        {
            cs[k] ~= cast(double)(snaps[2][k] - snaps[0][k]) / n;
            ps[k] ~= cast(double)(snaps[2][k] - snaps[1][k]) / n;
        }
    }
    Result res;
    res.variant = name;
    res.total = median(tot);
    res.build = median(bld);
    res.pass = median(pas);
    res.aux = median(aux);
    foreach (k; 0 .. nCtr)
    {
        res.ctr[k] = perf.slot[k] >= 0 ? median(cs[k]) : double.nan;
        res.passCtr[k] = perf.slot[k] >= 0 ? median(ps[k]) : double.nan;
    }
    res.checksum = check();
    return res;
}

long since(MonoTime t) => (MonoTime.currTime - t).total!"nsecs";

Result[] runConfig(size_t S)(const(Ev)[] evs, const(char)* pool, int n, string[] only)
{
    Result[] out_;
    bool want(string v) => only.length == 0 || only.canFind(v);
    auto aos = cast(Node!S*) malloc(cast(size_t) n * Node!S.sizeof);
    Soa!S soa;
    soa.alloc(n);
    LevelScratch L;
    L.alloc(n);
    auto cursor = cast(float*) malloc(n * 4);
    scope (exit)
    {
        free(aos);
        soa.release();
        L.release();
        free(cursor);
    }

    if (want("fused-aos"))
        out_ ~= measure("fused-aos", n, (out long b, out long p, out long x) {
            mark(0);
            auto t = MonoTime.currTime;
            buildAos!(true, S)(evs, pool, aos);
            b = since(t);
            mark(1);
        }, () => sumAos(aos, n, false));
    if (want("sep-aos"))
        out_ ~= measure("sep-aos", n, (out long b, out long p, out long x) {
            mark(0);
            auto t = MonoTime.currTime;
            buildAos!(false, S)(evs, pool, aos);
            b = since(t);
            mark(1);
            t = MonoTime.currTime;
            fitSweepAos(aos, n);
            p = since(t);
            mark(2);
        }, () => sumAos(aos, n, false));
    if (want("fused-soa"))
        out_ ~= measure("fused-soa", n, (out long b, out long p, out long x) {
            mark(0);
            auto t = MonoTime.currTime;
            buildSoa!(true, false, S)(evs, pool, soa);
            b = since(t);
            mark(1);
        }, () => sumSoa(soa, n, false));
    if (want("sep-soa"))
        out_ ~= measure("sep-soa", n, (out long b, out long p, out long x) {
            mark(0);
            auto t = MonoTime.currTime;
            buildSoa!(false, false, S)(evs, pool, soa);
            b = since(t);
            mark(1);
            t = MonoTime.currTime;
            fitSweepSoa(soa, n);
            p = since(t);
            mark(2);
        }, () => sumSoa(soa, n, false));
    if (want("sep-soa-rc"))
        out_ ~= measure("sep-soa-rc", n, (out long b, out long p, out long x) {
            mark(0);
            auto t = MonoTime.currTime;
            buildSoa!(false, false, S)(evs, pool, soa);
            b = since(t);
            mark(1);
            t = MonoTime.currTime;
            fitSweepSoaRc(soa, n);
            p = since(t);
            mark(2);
        }, () => sumSoa(soa, n, false));
    if (want("level-soa"))
        out_ ~= measure("level-soa", n, (out long b, out long p, out long x) {
            mark(0);
            auto t = MonoTime.currTime;
            buildSoa!(false, true, S)(evs, pool, soa);
            b = since(t);
            mark(1);
            t = MonoTime.currTime;
            x = fitLevel(soa, L, n);
            p = since(t);
            mark(2);
        }, () => sumSoa(soa, n, false));
    // rest of layout: timed part is the three passes only (build+fit untimed)
    if (want("rest-aos"))
        out_ ~= measure("rest-aos", n, (out long b, out long p, out long x) {
            buildAos!(true, S)(evs, pool, aos);
            mark(0);
            mark(1);
            auto t = MonoTime.currTime;
            growAos!(0, S)(aos, n);
            growAos!(1, S)(aos, n);
            x = since(t); // grow x+y
            positionsAos(aos, n, cursor);
            p = since(t);
            mark(2);
        }, () => sumAos(aos, n, true));
    if (want("rest-soa"))
        out_ ~= measure("rest-soa", n, (out long b, out long p, out long x) {
            buildSoa!(true, false, S)(evs, pool, soa);
            mark(0);
            mark(1);
            auto t = MonoTime.currTime;
            growSoa!(0, S)(soa, n);
            growSoa!(1, S)(soa, n);
            x = since(t);
            positionsSoa(soa, n, cursor);
            p = since(t);
            mark(2);
        }, () => sumSoa(soa, n, true));
    return out_;
}

void main(string[] args)
{
    string[] shapes = ["list", "panels"];
    int[] ns = [1_000, 10_000, 100_000, 1_000_000];
    int[] fats = [64, 128, 328];
    string[] only;
    for (size_t i = 1; i < args.length; ++i)
    {
        auto v = i + 1 < args.length ? args[i + 1] : "";
        switch (args[i])
        {
        case "--shape": shapes = v.split(","); ++i; break;
        case "--n": ns = v.split(",").to!(int[]); ++i; break;
        case "--fat": fats = v.split(",").to!(int[]); ++i; break;
        case "--variant": only = v.split(","); ++i; break;
        case "--reps": reps = v.to!int; ++i; break;
        default: stderr.writeln("unknown arg ", args[i]); exit(2);
        }
    }
    perf.open();
    stderr.writefln("perf counters open: %s", perf.nOpen);
    auto pool = cast(char*) malloc(poolLen);
    foreach (k; 0 .. poolLen)
        pool[k] = cast(char)('a' + k % 26);

    writeln("| shape | N | fat B | variant | total ns/node | build | pass | aux | cyc | ins | L1D miss | L2 miss | DRAM fill | pass cyc | pass L1D | pass DRAM | checksum |");
    writeln("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|");
    foreach (shape; shapes)
        foreach (n0; ns)
        {
            Gen g = shape == "list" ? genList(n0) : genPanels(n0);
            int n = g.nodes;
            stderr.writefln("# %s N=%s depth=%s maxFan=%s events=%s", shape, n, g.maxDepth, g.maxFan, g.evs.length);
            foreach (fat; fats)
            {
                Result[] rs;
                if (fat == 64)
                    rs = runConfig!64(g.evs, pool, n, only);
                else if (fat == 128)
                    rs = runConfig!128(g.evs, pool, n, only);
                else if (fat == 328)
                    rs = runConfig!328(g.evs, pool, n, only);
                else
                {
                    stderr.writeln("fat must be 64,128,328");
                    exit(2);
                }
                ulong ref_ = 0;
                foreach (r; rs)
                {
                    string ok;
                    if (r.variant.length >= 4 && r.variant[0 .. 4] == "rest")
                        ok = rs[$ - 1].checksum == r.checksum ? "ok" : "MISMATCH";
                    else
                    {
                        if (ref_ == 0)
                            ref_ = r.checksum;
                        ok = r.checksum == ref_ ? "ok" : "MISMATCH";
                    }
                    writefln("| %s | %s | %s | %s | %.2f | %.2f | %.2f | %.2f | %.1f | %.1f | %.2f | %.3f | %.3f | %.1f | %.2f | %.3f | %s %016x |",
                        shape, n, fat, r.variant, r.total, r.build, r.pass, r.aux,
                        r.ctr[0], r.ctr[1], r.ctr[2], r.ctr[3], r.ctr[4],
                        r.passCtr[0], r.passCtr[2], r.passCtr[4], ok, r.checksum);
                    stdout.flush();
                }
            }
        }
    if (multiplexed)
        stderr.writeln("WARNING: counters were multiplexed");
}
