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
keeps the status line alone.
*/
WidgetTree exitBanner(ExitInfo info, bool expanded, bool actions, ButtonLabels labels) @safe
{
    Builder b;
    uint[] lines;

    const ok = info.status == 0;
    const mark = label(b, (ok ? "✓ " : "✗ ") ~ statusText(info.status),
        ok ? Slot.success : Slot.error, bold: true);
    const cmd = label(b, info.command.length ? "· " ~ info.command : "", Slot.muted);
    const chevron = label(b, expanded ? "▴" : "▾", Slot.muted);
    auto status = row(b, [mark, cmd, chevron]);
    b.nodes[status].hitId = ExitHit.toggle;
    lines ~= status;

    if (expanded)
    {
        lines ~= label(b, info.command, Slot.textPrimary);
        if (info.cwd.length)
            lines ~= label(b, "cwd   " ~ info.cwd, Slot.textSecondary);
        if (info.started != SysTime.init)
            lines ~= label(b, "ran   " ~ ranText(info.started, info.ended), Slot.textSecondary);
    }
    if (actions)
        lines ~= row(b, [
            button(b, "↻", "Re-run", labels, ExitHit.rerun, primary: true),
            button(b, "❯", "Shell", labels, ExitHit.shell),
            button(b, "×", "Close", labels, ExitHit.close),
        ]);
    return b.finish(band(b, lines));
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

    // `hold`: the status line alone, no actions.
    auto held = place(exitBanner(info, false, false, ButtonLabels.iconText), 60, 20, 0, 0, 1, 1);
    assert(held.bounds.height == 1 && held.hits.length == 1);
}
