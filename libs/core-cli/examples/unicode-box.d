#!/usr/bin/env dub
/+ dub.sdl:
name "unicode-box"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
+/

module unicode_box_example;

// A self-running tour of the Unicode/ANSI correctness that `drawBox` inherits from
// `sparkles:base.text`. Each vignette streams one box via `drawBoxChunks!false`
// (so it types out cell-by-cell, like `streaming-box.d`) and is preceded by a
// caption naming the one thing to watch for. It needs no arguments, so it records
// cleanly; `--delay`, `--width`, and `--only` tune playback.
//
// What each vignette pins (all measured in terminal *cells*, never bytes):
//
//   1. CJK wide glyphs occupy 2 cells and never straddle the wrap column.
//   2. Combining marks cost 0 cells — an accented line aligns with a plain one.
//   3. Emoji (flags, ZWJ family, skin-tone, VS16) are each one 2-cell cluster.
//   4. A styled run that wraps re-emits its SGR per line; the frame never colors.
//   5. An OSC 8 hyperlink stays clickable even when it wraps mid-link.
//   6. NBSP forbids a break, ZWSP offers an invisible one, soft hyphen shows '-'.
//   7. A long CJK+emoji+styled title nests into its own mini-box and streams.
//   8. Grand tour: all of the above wrapped and streamed in one frame.
//
//   dub run --single unicode-box.d
//   dub run --single unicode-box.d -- --delay 0          # instant final frames
//   dub run --single unicode-box.d -- --only 3 --delay 30
//   dub run --single unicode-box.d -- --width 50

import core.thread : Thread;
import core.time : dur;
import std.range.primitives : ElementType, empty, front, popFront;
import std.stdio : stdout, write, writeln;

import sparkles.core_cli.args;
import sparkles.core_cli.ui.box : BoxProps, drawBoxChunks, TitleOverflow;
import sparkles.core_cli.ui.osc_link : oscLink;
import sparkles.base.term_style : Style, stylize;
import sparkles.base.text.grapheme : visibleWidth;

struct CliParams
{
    @CliOption("d|delay", "Animation delay per streamed chunk, in milliseconds")
    int delayMs = 14;

    @CliOption("w|width", "Override every vignette's box width (0 = per-vignette default)")
    int width = 0;

    @CliOption("only", "Play only the Nth vignette (1-based; 0 = all)")
    int only = 0;
}

/// A forward range that sleeps on each `popFront`, so consuming it animates output.
/// Paces the box's cell-granular chunks: each chunk is a word/segment (frame pieces
/// ride along for free), so iterating reveals the box token by token.
struct DelayedRange(R)
{
    private R _src;
    private int _delayMs;

    bool empty() => _src.empty;
    ElementType!R front() => _src.front;
    void popFront()
    {
        _src.popFront;
        if (!_src.empty)
            Thread.sleep(dur!"msecs"(_delayMs));
    }
}

auto delayedRange(R)(R src, int delayMs) => DelayedRange!R(src, delayMs);

/// One step of the tour: a caption telling the viewer what to watch, plus the box
/// (title + content lines + geometry) that demonstrates it.
struct Vignette
{
    string caption;
    string title;
    string[] content;
    BoxProps props;
}

void main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(HelpInfo(
        "unicode-box",
        "Unicode & ANSI feature tour for drawBox",
    ));

    auto vignettes = buildVignettes(cli.width);
    foreach (i, v; vignettes)
    {
        // `only` is 1-based; 0 plays the whole tour.
        if (cli.only > 0 && cli.only != cast(int)(i + 1))
            continue;

        writeln();
        writeln("▸ ".stylize(Style.cyan) ~ v.caption.stylize(Style.italic));

        // Stream the box: each chunk is a word/segment with its frame pieces; `write`
        // (not `writeln`) — the chunks carry their own newlines, and the bottom border
        // ends without one, so we add a trailing newline after the box.
        foreach (chunk; drawBoxChunks!false(v.content, v.title, v.props).delayedRange(cli.delayMs))
        {
            write(chunk);
            stdout.flush();
        }
        writeln();

        if (cli.only == 0)
            Thread.sleep(dur!"msecs"(650)); // a beat between vignettes
    }
}

// Emoji built from explicit code points so the (otherwise invisible) joiners and
// variation selectors are auditable in the source rather than hidden in a literal.
private enum flagUS = "\U0001F1FA\U0001F1F8";    // regional indicators U + S
private enum flagJP = "\U0001F1EF\U0001F1F5";    // J + P
private enum flagFR = "\U0001F1EB\U0001F1F7";    // F + R
private enum flagDE = "\U0001F1E9\U0001F1EA";    // D + E
private enum family = "\U0001F469\u200D\U0001F467"; // woman + ZWJ + girl
private enum thumbTone = "\U0001F44D\U0001F3FE"; // thumbs-up + skin-tone-5 modifier
private enum heartVs16 = "\u2764\uFE0F";         // heart + VS16 (emoji presentation, 2 cells)
private enum rocket = "\U0001F680";              // rocket (emoji presentation by default)

/// Build the tour. `width` (when non-zero) overrides every box's width cap so a
/// recording can be retargeted to a narrower/wider terminal without editing here.
Vignette[] buildVignettes(int width)
{
    // Per-vignette default cap, overridable from the CLI.
    size_t cap(size_t dflt) => width > 0 ? cast(size_t) width : dflt;

    // Vignette 2's two lines must have identical visible width for their borders to
    // align — that alignment is the proof that combining marks count as 0 cells.
    const plainLine = "Plain:    cafe resume naive jalapeno";
    const accentLine = "Accented: café résumé naïve jalapeño";
    assert(visibleWidth(plainLine) == visibleWidth(accentLine),
        "combining-marks vignette: the two lines must have equal visible width");

    return [
        Vignette(
            "Wide CJK glyphs are 2 cells each; the right border stays aligned and no"
                ~ " ideograph is split at the wrap column.",
            "CJK wide glyphs wrap as whole cells",
            [
                "世界 hello 世界 hello 世界 hello 世界 hello 世界",
                "日本語 と English を mix する 日本語 テスト 終わり",
            ],
            BoxProps(maxWidth: cap(30)),
        ),
        Vignette(
            "The accented line is base letters + combining marks; it has the same"
                ~ " visible width as the plain line, so both right borders line up.",
            "Combining marks cost 0 cells",
            [plainLine, accentLine],
            BoxProps(minWidth: cap(46), maxWidth: cap(46)),
        ),
        Vignette(
            "Flags (regional-indicator pairs), a ZWJ family, a skin-tone modifier and a"
                ~ " VS16-promoted heart are each ONE 2-cell cluster and wrap as a unit.",
            "Emoji: one 2-cell cluster each",
            [
                "Flags: " ~ flagUS ~ " " ~ flagJP ~ " " ~ flagFR ~ " " ~ flagDE
                    ~ " — every pair is 2 cells",
                "ZWJ family [" ~ family ~ "] skin tone [" ~ thumbTone ~ "] VS16 [" ~ heartVs16 ~ "]",
            ],
            BoxProps(maxWidth: cap(44)),
        ),
        Vignette(
            "A single styled run wraps several times; its SGR is suspended at each"
                ~ " border and re-emitted on the next line, so the frame never colors.",
            "Styling doesn't bleed onto the frame",
            [
                ("This long magenta sentence wraps across several lines; watch the frame"
                    ~ " keep its default color on every continuation line.").stylize(Style.magenta),
                ("A bold line that also wraps and re-emits its SGR after each border, so"
                    ~ " nothing leaks onto the frame.").stylize(Style.bold),
            ],
            BoxProps(maxWidth: cap(46)),
        ),
        Vignette(
            "This anchor text wraps mid-link; the link is closed at the border and"
                ~ " re-opened on the next line, so both halves stay clickable.",
            "OSC 8 hyperlinks survive a wrap",
            [
                oscLink(
                    "the sparkles core-cli drawBox documentation — a deliberately long"
                        ~ " anchor that has to wrap across more than one line",
                    "https://example.com/sparkles/core-cli/ui/box"),
            ],
            BoxProps(maxWidth: cap(40)),
        ),
        Vignette(
            "NBSP keeps measurements intact, ZWSP offers an invisible break, and the"
                ~ " soft hyphen's dash appears only when its break is actually used.",
            "Break opportunities: NBSP / ZWSP / soft hyphen",
            [
                "NBSP keeps 10\u00A0MB / 200\u00A0ms / 5\u00A0GHz from ever splitting",
                "ZWSP breaks super\u200Bcali\u200Bfragilistic\u200Bexpialidocious invisibly",
                "Soft hyphen shows docu\u00ADmentation's dash only when used to wrap",
            ],
            BoxProps(maxWidth: cap(32)),
        ),
        Vignette(
            "The long title (CJK + emoji + a styled word) nests into its own mini-box"
                ~ " and types out word by word before the body begins.",
            "Streaming nested title 世界 " ~ heartVs16 ~ " "
                ~ "overflowing".stylize(Style.cyan) ~ " past the width cap",
            [
                "The body appears only after the whole title has typed out word by word"
                    ~ " on the top border.",
            ],
            BoxProps(maxWidth: cap(36), titleOverflow: TitleOverflow.wrap),
        ),
        Vignette(
            "Everything together: wide CJK, emoji, and a styled clickable link, all"
                ~ " wrapped and streamed in one frame.",
            "Grand tour 世界 " ~ rocket,
            [
                "CJK 世界, emoji " ~ family ~ " " ~ heartVs16 ~ ", and a "
                    ~ oscLink("clickable styled link", "https://example.com/sparkles", Style.blue)
                    ~ " — all wrapped and streamed together.",
            ],
            BoxProps(maxWidth: cap(50), titleOverflow: TitleOverflow.wrap),
        ),
    ];
}
