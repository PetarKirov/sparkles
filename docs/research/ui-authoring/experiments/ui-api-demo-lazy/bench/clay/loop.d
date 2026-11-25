/// `loop <clay|stack> <depth> <frames>`: panel frames only, for `perf stat`.
module loop;

import std.conv : to;
import std.stdio : writefln;

import model;
static import lazystack, views_lazystack;
import clayui;
static import views_clay;

void main(string[] args)
{
    const d = args[2].to!uint, frames = args[3].to!uint;
    if (args[1] == "clay" || args[1] == "claybuild")
    {
        auto ui = new ClayUi!false;
        ui.setup(1 << 18);
        foreach (_; 0 .. frames)
        {
            ui.begin();
            views_clay.panel(*ui, d);
            if (args[1] == "clay") cast(void) ui.end();
        }
        writefln("%s elements", ui.elementCount);
    }
    else
    {
        auto ui = new lazystack.Ui;
        ui.expectMsg!StatsMsg;
        const env = lazystack.Env(lazystack.Layout.wide, lazystack.Density.comfortable);
        foreach (_; 0 .. frames)
        {
            cast(void) ui.frame(env, views_lazystack.panel(*ui, d));
            ui.reset();
        }
        writefln("%s nodes", ui.nodeCount);
    }
}
