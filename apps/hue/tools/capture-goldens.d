#!/usr/bin/env dub
/+ dub.sdl:
    name "capture-goldens"
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:syntax" path="../../.."
    dependency "sparkles:twoslash" path="../../.."
    dependency "sparkles:ui" path="../../.."
    dependency "sparkles:base" path="../../.."
+/
// Text goldens for the cross-backend renderers — the refactor's regression oracle.
//
// Its sibling `capture-modes.d` renders PNGs for a human to eyeball; this one
// renders the *text* each backend actually produces, so a machine can diff it.
// PNGs are the wrong oracle for a refactor: they are binary, they depend on
// fonts and a browser, and a one-pixel shift reads the same as a rewritten DOM.
// Every renderer here is deterministic and byte-comparable.
//
// Three renderings per fixture, all in-process (no X server, no Chrome):
//
//   .html     — the hand-authored `.twoslash-*` markup (`render_html`)
//   .ansi     — the terminal escape stream (`render_ansi`)
//   .widgets  — the same widget tree the GUI and TUI paint, via `interp/html`
//
// The third is the parity ground truth: `html` and `widgets` describe the same
// overlay through two independent emitters, so a change that alters one and not
// the other is exactly the drift this refactor must not introduce.
//
//   # record the baseline, then after a change:
//   dub run --single apps/hue/tools/capture-goldens.d -- --out /tmp/goldens
//   dub run --single apps/hue/tools/capture-goldens.d -- --out /tmp/after
//   diff -ru /tmp/goldens /tmp/after
//
// Exits non-zero if any fixture fails to render, so it doubles as a smoke test.
module capture_goldens;

import std.algorithm : filter, map, sort;
import std.array : appender, array;
import std.file : dirEntries, exists, mkdirRecurse, write, SpanMode;
import std.path : baseName, buildPath;
import std.stdio : stderr, writefln, writeln;
import std.string : endsWith;

import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : RgbColor;
import sparkles.syntax;
import sparkles.twoslash;

/// CLI surface. Descriptions carry no double quotes — `parseCliArgs` splices
/// them into generated code verbatim.
struct Params
{
    @CliOption("out|o", "Output directory for the goldens")
    string outDir = "golden-out";

    @CliOption("fixtures|f", "Directory of *.twoslash.json fixtures")
    string fixturesDir = "libs/twoslash/examples/fixtures";

    @CliOption("theme|t", "Theme name from builtinThemes")
    string theme = "catppuccin-mocha";
}

// The GUI page colors, so the palette resolves the same dark surface/docs the
// raster backends do. Matching `capture-modes` keeps the two harnesses aligned.
private enum pageFg = RgbColor(0xcd, 0xd6, 0xf4);
private enum pageBg = RgbColor(0x1e, 0x1e, 0x2e);

int main(string[] args) @system
{
    auto p = args.parseCliArgs!Params(HelpInfo("capture-goldens",
        "Record text goldens for the cross-backend twoslash renderers — " ~
        "deterministic and byte-comparable, unlike the PNG harness.", null));

    if (!p.fixturesDir.exists)
    {
        stderr.writeln("no fixtures directory: ", p.fixturesDir);
        return 1;
    }
    p.outDir.mkdirRecurse;

    auto fixtures = p.fixturesDir
        .dirEntries(SpanMode.shallow)
        .filter!(e => e.name.endsWith(".twoslash.json"))
        .map!(e => e.name)
        .array;
    fixtures.sort();

    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(p.theme, builtinDark), labels);
    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, labels);

    size_t failed;
    foreach (fixture; fixtures)
    {
        const stem = fixture.baseName(".twoslash.json");
        auto twRes = loadTwoslashFile(fixture);
        if (twRes.hasError)
        {
            stderr.writeln("  ", stem, ": load failed");
            ++failed;
            continue;
        }
        const tw = twRes.value;

        // One highlight pass feeds all three renderers, so a difference between
        // them is a renderer difference and never an input difference.
        SmallBuffer!HighlightEvent events;
        if (highlightInjected(cache, "typescript", tw.code, events).hasError)
            events ~= HighlightEvent.sourceSpan(0, tw.code.length);

        write(buildPath(p.outDir, stem ~ ".html"), renderHtml(tw, events[], theme, cache));
        write(buildPath(p.outDir, stem ~ ".ansi"), renderAnsi(tw, events[], theme, cache));
        write(buildPath(p.outDir, stem ~ ".widgets.html"), renderWidgets(tw, stem));
        writefln("  %s", stem);
    }

    writefln("%s fixture(s), %s failed", fixtures.length, failed);
    return failed ? 1 : 0;
}

/// The hand-authored `.twoslash-*` markup, with the theme stylesheet inlined so
/// the golden captures palette changes too.
private string renderHtml(in TwoslashReturn tw, in HighlightEvent[] events,
    in ResolvedTheme theme, ref TsConfigCache cache) @system
{
    SmallBuffer!char out_;
    out_ ~= "<style>\n";
    writeThemeStylesheet(theme, out_);
    writeTwoslashStyles(out_);
    out_ ~= "</style>\n<pre class=\"syn-root twoslash\"><code>";
    renderTwoslashHtml(tw, events, theme, cache, out_);
    out_ ~= "</code></pre>\n";
    return out_[].idup;
}

/// The terminal escape stream. Escapes are kept literal — they are the payload
/// under test, and a golden that stripped them would not catch an SGR change.
private string renderAnsi(in TwoslashReturn tw, in HighlightEvent[] events,
    in ResolvedTheme theme, ref TsConfigCache cache) @system
{
    SmallBuffer!char out_;
    renderTwoslashAnsi(tw, events, theme, cache, out_);
    return out_[].idup;
}

/// The widget tree the GUI and TUI paint, rendered through the HTML interpreter
/// — the backend-neutral description, independent of any canvas.
private string renderWidgets(in TwoslashReturn tw, string stem) @system
{
    import sparkles.ui.interp.html : writeWidgetHtmlPage;
    import sparkles.ui.style : defaultTwoslashPalette, schemeForBackground;
    import sparkles.twoslash.render_widgets : viewTwoslash;

    const pal = defaultTwoslashPalette(schemeForBackground(pageBg));
    auto w = appender!string;
    writeWidgetHtmlPage(w, viewTwoslash(tw), pal, pageFg, pageBg, stem);
    return w[];
}
