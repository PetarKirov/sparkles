#!/usr/bin/env dub
/+ dub.sdl:
name "table-leaderboard"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
+/

module table_leaderboard_example;

// A live leaderboard: `drawTableLines` renders each frame as a forward range of
// newline-less lines — exactly what `LiveRegion.update` wants — so the whole
// table is repainted in place every tick while rows re-sort as scores move.
// The top three ranks wear medals, a trend column shows how far each team moved
// since the previous tick, and every lead change graduates into the scrollback
// above the region via `printAbove` — demonstrating both LiveRegion channels.
//
// The score walk is seeded (`--seed`), so a given invocation is reproducible.
// Piped (non-tty) output skips the animation entirely: only the lead-change
// lines and the final standings are printed.
//
//   dub run --single table-leaderboard.d
//   dub run --single table-leaderboard.d -- --teams 8 --ticks 60 --interval 50
//   dub run --single table-leaderboard.d -- --seed 7 --ticks 25

import core.thread : Thread;
import core.time : dur;
import std.conv : text;
import std.stdio : writeln;

import sparkles.core_cli.args;
import sparkles.core_cli.ui.live : stdoutLiveRegion;
import sparkles.core_cli.ui.table : drawTableLines, TableProps;
import sparkles.base.styled_template : styledText;
import sparkles.base.text.width : Align;

struct CliParams
{
    @CliOption("n|teams", "Number of competing teams")
    int teams = 6;

    @CliOption("t|ticks", "Number of score updates before the race ends")
    int ticks = 40;

    @CliOption("i|interval", "Milliseconds between frames")
    int intervalMs = 80;

    @CliOption("s|seed", "Random seed for the score walk (a fixed seed replays the same race)")
    uint seed = 42;
}

/// A competitor: display name plus its running score.
struct Team
{
    string name;
    int score;
}

void main(string[] args)
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.random : Mt19937, uniform;

    const cli = args.parseCliArgs!CliParams(HelpInfo(
        "table-leaderboard",
        "Live re-sorting leaderboard (drawTableLines + LiveRegion)"));

    auto rng = Mt19937(cli.seed);
    auto teams = makeTeams(cli.teams);
    // Every team starts from a distinct-ish baseline so tick 0 already ranks.
    foreach (ref t; teams)
        t.score = uniform(40, 61, rng);

    auto region = stdoutLiveRegion();
    scope (exit) region.finish();

    size_t[string] prevRank;
    string leader;
    string[] lastFrame;
    foreach (tick; 0 .. cli.ticks)
    {
        if (tick > 0)
            foreach (ref t; teams)
                t.score += uniform(0, 12, rng);
        teams.sort!((a, b) => a.score != b.score ? a.score > b.score : a.name < b.name);

        if (teams.length && teams[0].name != leader)
        {
            const newLeader = teams[0].name;
            if (leader.length) // the very first leader is not a "change"
                region.printAbove(styledText(
                    i"🏆 {bold.yellow $(newLeader)} takes the lead at tick $(tick)"));
            leader = newLeader;
        }

        auto cells = frameCells(teams, prevRank, tick);
        auto props = frameProps(tick, cli.ticks);
        lastFrame = drawTableLines(cells, props).array;
        region.update(lastFrame);

        foreach (rank, ref t; teams)
            prevRank[t.name] = rank;

        // Only an interactive terminal sees the frames — don't slow piped runs.
        if (region.interactive && tick + 1 < cli.ticks)
            Thread.sleep(dur!"msecs"(cli.intervalMs));
    }

    // Piped runs saw no frames; print the final standings (last frame) once.
    if (!region.interactive)
        foreach (line; lastFrame)
            writeln(line);
}

/// The first `n` team names (i18n + emoji so the table proves cell-width
/// measurement every frame), numbered past the roster's end.
Team[] makeTeams(int n)
{
    static immutable names = [
        "Ravens", "红龙", "Búhos", "Wolves 🐺", "Kraken 🐙",
        "Falcons", "Zmajevi", "Δράκοι",
    ];
    Team[] teams;
    foreach (i; 0 .. n)
        teams ~= Team(i < names.length
            ? names[i]
            : text(names[i % $], " ", i / names.length + 1));
    return teams;
}

/// One frame of the leaderboard as table cells: medals for the top three, the
/// score, and a trend arrow showing how far the team moved since the last tick.
string[][] frameCells(in Team[] teams, size_t[string] prevRank, int tick)
{
    string[][] cells = [[
        styledText(i"{bold rank}"),
        styledText(i"{bold team}"),
        styledText(i"{bold score}"),
        styledText(i"{bold trend}"),
    ]];
    foreach (rank, ref t; teams)
        cells ~= [
            rankLabel(rank),
            t.name,
            text(t.score),
            trendLabel(rank, t.name in prevRank ? prevRank[t.name] : rank, tick),
        ];
    return cells;
}

/// ditto
TableProps frameProps(int tick, int ticks)
{
    return TableProps(
        headerRows: 1,
        title: styledText(i"{bold Leaderboard}"),
        footer: text("tick ", tick + 1, "/", ticks),
        columnAligns: [Align.right, Align.left, Align.right, Align.left],
    );
}

/// Medals for the podium, plain numbers below it.
string rankLabel(size_t rank)
{
    static immutable medals = ["🥇", "🥈", "🥉"];
    return rank < medals.length ? medals[rank] : text(rank + 1);
}

/// How far a team moved since the previous tick: ↑n / ↓n / · (unchanged).
string trendLabel(size_t rank, size_t prev, int tick)
{
    if (tick == 0 || rank == prev)
        return styledText(i"{dim ·}");
    return rank < prev
        ? styledText(i"{green ↑$(prev - rank)}")
        : styledText(i"{red ↓$(rank - prev)}");
}
