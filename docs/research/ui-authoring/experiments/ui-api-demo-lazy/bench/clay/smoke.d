/// Standalone check: Clay's trees equal lazy-stack's, and frame timings.
module smoke;

import core.time : MonoTime;
import std.format : format;
import std.stdio : writefln;

import model;
static import lazystack, views_lazystack;
import clayui;
static import views_clay;

const(MemberRow)[] makeRows(size_t n)
{
    auto rows = new MemberRow[n];
    foreach (i, ref r; rows)
        r = MemberRow(format("row%06d", i), format("value-%06d", i));
    return rows;
}

void main()
{
    const stats = Stats(true, 300);
    foreach (shape; ["stats", "panels"])
    foreach (size; shape == "stats" ? [10, 1000, 100_000] : [4, 9, 14])
    {
        if (shape == "stats" && size > ushort.max)
        {
            writefln("stats %s: skipped, Clay counts an element's children in a uint16_t", size);
            continue;
        }
        const ids = IdsView(true, "ab", shape == "stats" ? makeRows(size) : null);
        auto ref_ = new lazystack.Ui;
        ref_.expectMsg!StatsMsg;
        const env = lazystack.Env(lazystack.Layout.wide, lazystack.Density.comfortable);
        const root = shape == "stats"
            ? ref_.frame(env, views_lazystack.statsPane(*ref_, stats, ids))
            : ref_.frame(env, views_lazystack.panel(*ref_, cast(uint) size));
        ulong eh; size_t ec;
        ref_.checksum(root, eh, ec);

        static foreach (side; [false, true])
        {{
            auto ui = new ClayUi!side;
            ui.setup(cast(int) ec + 16);
            void frame(bool full)
            {
                ui.begin();
                if (shape == "stats") views_clay.statsPane(*ui, stats, ids);
                else views_clay.panel(*ui, cast(uint) size);
                if (full) cast(void) ui.end();
            }
            foreach (full; [false, true])
            {
                frame(full);
                ulong h; size_t c;
                ui.checksum(ui.viewRoot, h, c);
                assert(h == eh && c == ec, format("%s/%s side=%s full=%s: %s #%x vs %s #%x",
                    shape, size, side, full, c, h, ec, eh));
                if (!full) cast(void) ui.end();
                ui.reset();
            }
            // first frames on a fresh context vs steady state (build and end timed apart)
            auto fresh = new ClayUi!side;
            fresh.setup(cast(int) ec + 16);
            double[2][3] ns = 0; // [first, second, steady][build, end]
            enum reps = 20;
            foreach (f; 0 .. 2 + reps)
            {
                auto t0 = MonoTime.currTime;
                fresh.begin();
                if (shape == "stats") views_clay.statsPane(*fresh, stats, ids);
                else views_clay.panel(*fresh, cast(uint) size);
                auto t1 = MonoTime.currTime;
                cast(void) fresh.end();
                auto t2 = MonoTime.currTime;
                fresh.reset();
                const k = f < 2 ? f : 2;
                const div = (f < 2 ? 1.0 : reps) * ec;
                ns[k][0] += (t1 - t0).total!"nsecs" / div;
                ns[k][1] += (t2 - t1).total!"nsecs" / div;
            }
            writefln("%-6s %6s side=%d: mem %5.1f MiB, dup ids %s, errors %s; ns/node build first/second/steady %.0f/%.0f/%.0f, end %.0f/%.0f/%.0f",
                shape, size, side, fresh.memorySize / 1048576.0, fresh.duplicateIds, fresh.errorCount,
                ns[0][0], ns[1][0], ns[2][0], ns[0][1], ns[1][1], ns[2][1]);
            destroy(*fresh);
            destroy(*ui);
        }}
    }
}
