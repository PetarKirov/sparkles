/// Prints what README.md quotes: node counts, a toggle's tree in each library,
/// the semantics tree, and the custom layouts' trees.
module demo;

import std.stdio : writefln, writeln, write;

import uicore;
import model;
import layouts;
static import views_pure, views_hybrid, widgets_pure, widgets_hybrid;

void printTree(ref const Ui ui)
{
    ui.dump((uint d, scope const(char)[] l) { foreach (_; 0 .. d) write("  "); writeln(l); });
}

void printSem(ref const Ui ui)
{
    ui.semantics((uint d, scope const(char)[] l) { foreach (_; 0 .. d) write("  "); writeln(l); });
}

MemberRow[] makeRows(size_t n)
{
    import std.format : format;
    auto rs = new MemberRow[n];
    foreach (i, ref r; rs)
        r = MemberRow(format("row%06d", i), format("value-%06d", i));
    return rs;
}

void main()
{
    auto rows = makeRows(1000);
    const ids = IdsView(true, "ab", rows);
    Settings s;
    s.flags = [true, false, true, false, true, false, false, true];
    s.numbers = [4, 13, 120, 300, 1000, 80, 30, 8];
    s.name = "sparkles";

    writeln("== node counts ==");
    foreach (lib; ["pure", "hybrid"])
    {
        auto ui = new Ui;
        ui.expectMsg!StatsMsg;
        cast(void) (lib == "pure" ? ui.frame(Env(), views_pure.statsPane(*ui, Stats(true, 300), ids))
            : ui.frame(Env(), views_hybrid.statsPane(*ui, Stats(true, 300), ids)));
        const stats = ui.nodeCount;
        ui.reset();
        ui.expectMsg!SettingsMsg;
        cast(void) (lib == "pure" ? ui.frame(Env(), views_pure.settingsPage(*ui, s, ids))
            : ui.frame(Env(), views_hybrid.settingsPage(*ui, s, ids)));
        writefln("%-6s  statsPane(1000 rows): %5s   settingsPage(1000-row virtual list): %4s", lib, stats, ui.nodeCount);
    }

    writeln("\n== one toggle, pure ==");
    {
        auto ui = new Ui;
        cast(void) ui.frame(Env(), widgets_pure.toggle(*ui, on: true, label: "Autosave"));
        ui.layOut(40, 5);
        printTree(*ui);
        DrawList dl;
        ui.paint(dl);
        writefln("draw ops: %s", dl.length);
    }
    writeln("== one toggle, hybrid ==");
    {
        auto ui = new Ui;
        cast(void) ui.frame(Env(), widgets_hybrid.toggle(*ui, on: true, label: "Autosave"));
        ui.layOut(40, 5);
        printTree(*ui);
        DrawList dl;
        ui.paint(dl);
        writefln("draw ops: %s", dl.length);
    }

    writeln("\n== settings page semantics (pure and hybrid print the same; first 24 lines) ==");
    {
        auto ui = new Ui;
        ui.expectMsg!SettingsMsg;
        cast(void) ui.frame(Env(), views_pure.settingsPage(*ui, s, ids));
        ui.layOut(80, 40);
        size_t n;
        ui.semantics((uint d, scope const(char)[] l) {
            if (n++ < 24) { foreach (_; 0 .. d) write("  "); writeln(l); }
        });
        writefln("… %s semantic nodes", n);
    }

    writeln("\n== clock (a)+(c) ==");
    {
        auto ui = new Ui;
        cast(void) ui.frame(Env(), (*ui).clockFace(hour: 3));
        ui.layOut(80, 40);
        printTree(*ui);
        char[21][21] grid;
        foreach (ref r; grid) r[] = ' ';
        foreach (i; 0 .. cast(uint) ui.nodeCount)
            if ((*ui)[Node(i)].kind == Kind.text)
            {
                const t = ui.textOf(Node(i));
                const r = ui.rectOf(Node(i));
                foreach (j, c; t) grid[r.y][r.x + j] = c;
            }
        foreach (ref r; grid) writeln("|", r[], "|");
    }

    writeln("\n== timeline (a) ==");
    {
        static immutable Event[] evs = [Event(0, 10, "a"), Event(5, 20, "b"), Event(12, 15, "long label"),
            Event(16, 18, "d"), Event(21, 30, "c")];
        auto ui = new Ui;
        ui.expectMsg!CustomMsg;
        cast(void) ui.frame(Env(), timelineView(*ui, evs, 0, 100, 40));
        ui.layOut(80, 40);
        printTree(*ui);
        printSem(*ui);
    }

    writeln("\n== calendar (a) ==");
    {
        static immutable CalEvent[] evs = [CalEvent(0, 540, 600, "Standup"), CalEvent(0, 570, 660, "Review"),
            CalEvent(0, 630, 690, "Pairing"), CalEvent(0, 720, 780, "Lunch"), CalEvent(1, 540, 600, "Planning")];
        auto ui = new Ui;
        ui.expectMsg!CustomMsg;
        cast(void) ui.frame(Env(), calendarView(*ui, evs, 70, 2));
        ui.layOut(80, 40);
        printTree(*ui);
    }
}
