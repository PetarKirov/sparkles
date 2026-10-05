/**
The exit prompt's banner (`TSS2`, mockup E1): across the bottom of an exited
pane, over its last screen. A status line — the exit status or the signal,
marked with a glyph as well as a colour (`ACC3`), and the command on one line
— that expands, when activated, to the whole command, its directory and when
it ran; then the actions: Re-run, Shell, Close.

A pure view: the host supplies what ran and whether the line is expanded, and
maps the hit ids back to commands.
*/
module exit_banner;

import std.datetime.systime : SysTime;

import sparkles.ui.widget : Builder, WidgetTree;

import chrome : band, button, column, label, row;
import settings : ButtonLabels;
import sparkles.ui.style : Slot;

/// What ran in the pane, for the banner.
struct ExitInfo
{
    /// The exit status; 128 + n for a death by signal n.
    int status;
    /// The command, or the shell's name.
    string command;
    /// The directory it ran in.
    string cwd;
    /// When it started and ended (`SysTime.init`: unknown).
    SysTime started, ended;
}

/// The banner's targets.
enum ExitHit : size_t
{
    none,
    toggle = 0x1E00, /// the status line: expand or collapse
    rerun,
    shell,
    close,
}

/// The status line's words: "exited with status 1", "killed by signal 9".
string statusText(int status) @safe pure
{
    import std.conv : text;

    if (status == 0)
        return "exited";
    if (status > 128 && status < 128 + 65)
        return text("killed by signal ", status - 128);
    return text("exited with status ", status);
}

/**
The banner for `info`, at most `cols` wide. `expanded` shows the whole command
with its directory and times; `actions` is false for `onExit = hold`, which
keeps the status line alone; `targetRows` makes the buttons touch targets.

Expanded, the command wraps at `wrapCols` and takes at most `commandRows`
rows; a longer one shows the window `scroll` lines down (`commandScroll`
clamps it), with how many lines lie above and below (`TSS2`).
*/
WidgetTree exitBanner(ExitInfo info, bool expanded, bool actions, ButtonLabels labels,
    int targetRows = 1, int wrapCols = int.max, int commandRows = int.max, int scroll = 0) @safe
{
    Builder b;
    uint[] lines;

    const ok = info.status == 0;
    const mark = label(b, (ok ? "✓ " : "✗ ") ~ statusText(info.status),
        ok ? Slot.success : Slot.error, bold: true);
    // The status is the line's point: a long command gives way to it.
    {
        import sparkles.base.text.grapheme : visibleWidth;

        b.nodes[mark].width.min = cast(int) visibleWidth(b.nodes[mark].text);
    }
    const cmd = label(b, info.command.length ? "· " ~ info.command : "", Slot.muted);
    const chevron = label(b, expanded ? "▴" : "▾", Slot.muted);
    auto status = row(b, [mark, cmd, chevron]);
    b.nodes[status].hitId = ExitHit.toggle;
    lines ~= status;

    if (expanded)
    {
        import std.conv : text;

        const all = commandLines(info.command, wrapCols);
        const room = commandRoom(all.length, commandRows);
        const first = commandScroll(all.length, commandRows, scroll);
        if (first)
            lines ~= label(b, text("↑ ", first, first == 1 ? " line" : " lines"), Slot.muted);
        foreach (l; all[first .. first + room])
            lines ~= label(b, l, Slot.textPrimary);
        if (const below = all.length - first - room)
            lines ~= label(b, text("↓ ", below, below == 1 ? " line" : " lines"), Slot.muted);
        if (info.cwd.length)
            lines ~= label(b, "cwd   " ~ info.cwd, Slot.textSecondary);
        if (info.started != SysTime.init)
            lines ~= label(b, "ran   " ~ ranText(info.started, info.ended), Slot.textSecondary);
    }
    if (actions)
        lines ~= row(b, [
            button(b, "↻", "Re-run", labels, ExitHit.rerun, primary: true, minRows: targetRows),
            button(b, "❯", "Shell", labels, ExitHit.shell, minRows: targetRows),
            button(b, "×", "Close", labels, ExitHit.close, minRows: targetRows),
        ]);
    return b.finish(band(b, lines));
}

/**
`command` in lines at most `width` cells, using the allocating UI cell-plan
adapter's owned Unicode opportunities. A path or URL wider than a line is
split only at whole-grapheme boundaries, not at arbitrary byte positions.
*/
string[] commandLines(string command, int width) @safe
{
    import sparkles.ui.wrap : wrapLines;
    string[] lines;
    foreach (line; wrapLines(command, width > 0 ? width : 0))
        lines ~= line.idup;
    return lines;
}

// How many of `total` command lines show in `budget` rows: all of them when
// they fit, else two fewer, for the lines-above and lines-below marks.
private size_t commandRoom(size_t total, int budget) @safe pure nothrow @nogc
{
    const b = budget < 1 ? 1 : cast(size_t) budget;
    return total <= b ? total : b > 2 ? b - 2 : 1;
}

/// `scroll` clamped to the first line a window of `budget` rows may show.
size_t commandScroll(size_t total, int budget, int scroll) @safe pure nothrow @nogc
{
    const room = commandRoom(total, budget);
    const last = total - room;
    return scroll < 0 ? 0 : scroll > last ? last : scroll;
}

/// "09:41:07 – 09:43:52 (2 min 45 s)".
private string ranText(SysTime started, SysTime ended) @safe
{
    import std.format : format;

    static string clock(SysTime t) @safe
        => format("%02d:%02d:%02d", t.hour, t.minute, t.second);

    if (ended == SysTime.init)
        return clock(started);
    const secs = (ended - started).total!"seconds";
    const took = secs >= 3600 ? format("%d h %d min", secs / 3600, secs % 3600 / 60)
        : secs >= 60 ? format("%d min %d s", secs / 60, secs % 60)
        : format("%d s", secs);
    return clock(started) ~ " – " ~ clock(ended) ~ " (" ~ took ~ ")";
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("exit_banner.statusText.signalsAreNamed")
@safe pure unittest
{
    assert(statusText(0) == "exited");
    assert(statusText(1) == "exited with status 1");
    assert(statusText(128 + 9) == "killed by signal 9");
    assert(statusText(255) == "exited with status 255");
}

@("exit_banner.exitBanner.collapsedExpandedAndHold")
@safe unittest
{
    import std.array : join;
    import std.range : repeat;
    import std.algorithm.searching : canFind;
    import std.datetime : DateTime, seconds;

    import chrome : place, Place;

    const t0 = SysTime(DateTime(2026, 10, 2, 9, 41, 7));
    const info = ExitInfo(1, "nix build .#terminal-apk", "/home/u/sparkles", t0, t0 + 165.seconds);

    // Collapsed: the status line and the actions, two rows.
    auto collapsed = place(exitBanner(info, false, true, ButtonLabels.iconText), 60, 20, 0, 0, 1, 1);
    assert(collapsed.bounds.height == 2);
    size_t[] ids;
    foreach (ref t; collapsed.hits)
        ids ~= t.hitId;
    assert(ids.canFind(ExitHit.toggle) && ids.canFind(ExitHit.rerun)
        && ids.canFind(ExitHit.shell) && ids.canFind(ExitHit.close));

    // Expanded: the command, the directory and the times join.
    auto expanded = place(exitBanner(info, true, true, ButtonLabels.iconText), 60, 20, 0, 0, 1, 1);
    assert(expanded.bounds.height == 5);
    bool sawRan;
    foreach (ref n; expanded.tree.nodes)
        sawRan |= n.text.canFind("09:41:07 – 09:43:52 (2 min 45 s)");
    assert(sawRan);

    // A command far wider than the banner never squeezes out the status.
    auto squeezed = place(exitBanner(ExitInfo(3, "x".repeat(200).join), false, false,
        ButtonLabels.iconText), 40, 20, 0, 0, 1, 1);
    foreach (i, ref n; squeezed.tree.nodes)
        if (n.text == "✗ exited with status 3")
            assert(squeezed.frames[i].rect.width >= 22);

    // `hold`: the status line alone, no actions.
    auto held = place(exitBanner(info, false, false, ButtonLabels.iconText), 60, 20, 0, 0, 1, 1);
    assert(held.bounds.height == 1 && held.hits.length == 1);
}

@("exit_banner.commandLines.wrapsAndSplitsLongWords")
@safe unittest
{
    assert(commandLines("make -j8 all", 80) == ["make -j8 all"]);
    assert(commandLines("make -j8 all", 8) == ["make -j8", "all"]);
    import std.algorithm.searching : canFind;
    import std.array : join;
    import std.string : replace;
    import sparkles.base.text.grapheme : visibleWidth;

    // Unicode opportunities may change exact path breaks; neither cells nor
    // command contents may be lost, and an extended grapheme stays on one row.
    foreach (command; ["cat /a/very/long/path", "cat é/日本語/👩‍💻/long/path"])
    {
        const lines = commandLines(command, 8);
        foreach (line; lines)
            assert(visibleWidth(line) <= 8);
        assert(lines.join.replace(" ", "") == command.replace(" ", ""));
        foreach (cluster; ["é", "👩‍💻"])
            if (command.canFind(cluster))
            {
                bool intact;
                foreach (line; lines)
                    intact |= line.canFind(cluster);
                assert(intact, "command wrapping split an extended grapheme");
            }
    }
    assert(commandLines("", 8) == [""]);
}

@("exit_banner.exitBanner.aLongCommandScrolls")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import std.range : repeat;
    import std.array : join;

    import chrome : place, Place;

    // Twenty words of ten cells: ten 20-cell lines, in a budget of 5 rows —
    // three show, with the marks above and below (`TSS2`).
    const command = "abcdefghi".repeat(20).join(" ");
    const info = ExitInfo(1, command);
    assert(commandLines(command, 20).length == 10);
    assert(commandScroll(10, 5, 0) == 0 && commandScroll(10, 5, 99) == 7
        && commandScroll(10, 5, -3) == 0);
    assert(commandScroll(3, 5, 4) == 0, "what fits never scrolls");

    const(char)[][] texts(int scroll)
    {
        const(char)[][] t;
        auto l = place(exitBanner(info, true, false, ButtonLabels.iconText, 1, 20, 5, scroll),
            40, 30, 0, 0, 1, 1, Place.top);
        foreach (ref n; l.tree.nodes)
            if (n.text.length)
                t ~= n.text;
        return t;
    }

    auto top = texts(0);
    assert(!top.canFind!(t => t.canFind("↑")) && top.canFind("↓ 7 lines"));
    auto mid = texts(2);
    assert(mid.canFind("↑ 2 lines") && mid.canFind("↓ 5 lines"));
    auto end = texts(99);
    assert(end.canFind("↑ 7 lines") && !end.canFind!(t => t.canFind("↓")));
}
