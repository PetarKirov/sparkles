#!/usr/bin/env dub
/+ dub.sdl:
    name "capture-modes"
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:syntax" path="../../.."
    dependency "sparkles:twoslash" path="../../.."
    dependency "sparkles:ui" path="../../.."
    dependency "sparkles:base" path="../../.."
+/
// Twoslash QA capture harness: renders every fixture in all three `hue --twoslash`
// backends — GUI (raylib), TUI (terminal cell grid), and HTML — to PNGs in one
// directory, so a reviewer eyeballs parity across modes without hand-driving each
// backend. Speeds up the GUI↔TUI↔HTML parity QA loop.
//
// A real `sparkles` consumer (per the D-tooling guideline): it renders the HTML
// mode IN-PROCESS through `sparkles:twoslash` + `sparkles:syntax` (the same
// catppuccin theme + grammar the binary uses, so the comparison is apples-to-
// apples) and parses its own CLI with `sparkles:core-cli`. Only the two modes that
// are irreducibly a separate process shell out to the built `hue` binary: the
// raylib GUI (needs an X server, via `xvfb-run`) and the interactive TUI (its
// cell-frame renderer still lives in `apps/hue`; it moves to a lib with the
// GUI→widget migration, after which this tool renders the TUI in-process too).
//
// PNGs come from a headless Chrome (`google-chrome-stable`/`chromium`) for HTML +
// the TUI frame, and from raylib's screenshot for the GUI. Missing tools degrade
// gracefully. `--hover N` opens the Nth hover popup in every mode.
//
//   dub run --single apps/hue/tools/capture-modes.d -- --out /tmp/parity --hover 0
//   dub run --single apps/hue/tools/capture-modes.d -- --modes html 08-jsdoc 02-query
module capture_modes;

import std.algorithm : canFind, map, sort;
import std.array : array, replace;
import std.file : dirEntries, exists, mkdirRecurse, write, SpanMode;
import std.format : format;
import std.path : absolutePath, baseName, buildPath;
import std.process : Config, environment, execute, executeShell, spawnProcess, wait;
import std.stdio : stderr, writeln;
import std.string : split, strip;

import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.syntax;
import sparkles.twoslash;

/// CLI surface (parsed by `sparkles:core-cli`). Descriptions carry no double
/// quotes — `parseCliArgs` splices them into generated code verbatim.
struct Params
{
    @CliOption("out|o", "Output directory for the PNGs")
    string outDir = "capture-out";

    @CliOption("fixtures|f", "Directory of *.twoslash.json fixtures")
    string fixturesDir = "libs/twoslash/examples/fixtures";

    @CliOption("hue", "Path to the built hue binary (GUI + TUI modes)")
    string hueBin = "apps/hue/build/hue";

    @CliOption("modes|m", "Comma list of modes to render: gui, tui, html, widgets-html")
    string modes = "gui,tui,html,widgets-html";

    @CliOption("size|s", "TUI capture grid as cols x rows")
    string size = "100x30";

    @CliOption("theme", "Syntax theme name (matches the hue default)")
    string theme = "catppuccin-mocha";

    @CliOption("hover", "Open the Nth hover popup in every mode (-1 = resting)")
    int hover = -1;
}

int main(string[] args)
{
    auto p = args.parseCliArgs!Params(HelpInfo("capture-modes",
        "Render twoslash fixtures in GUI, TUI and HTML to PNGs for parity QA. " ~
        "Positional args pick fixtures by stem (e.g. 08-jsdoc); default is all.", null));

    const wantModes = p.modes.split(",").map!strip.array;
    const needBinary = wantModes.canFind("gui") || wantModes.canFind("tui");
    if (needBinary && !p.hueBin.exists)
    {
        stderr.writeln("capture-modes: hue binary not found at '", p.hueBin,
            "' — run `dub build :hue` first, or pass --hue (or --modes html).");
        return 1;
    }

    // The grammar bundle drives highlighting (in-process and in the binary). Honour
    // the env, else resolve it from the flake once and export it for both.
    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
    {
        const g = nixGrammarPath();
        if (g.length)
            environment["SPARKLES_TS_GRAMMAR_PATH"] = g;
    }

    p.outDir.mkdirRecurse;
    const outAbs = p.outDir.absolutePath;
    const hueAbs = p.hueBin.exists ? p.hueBin.absolutePath : p.hueBin;

    string[] stems = args[1 .. $];
    if (stems.length == 0)
        stems = dirEntries(p.fixturesDir, "*.twoslash.json", SpanMode.shallow)
            .map!(e => e.name.baseName.replace(".twoslash.json", "")).array;
    stems.sort();

    const chrome = findFirst(["google-chrome-stable", "google-chrome", "chromium", "chromium-browser"]);
    const haveXvfb = findFirst(["xvfb-run"]).length > 0;
    if ((wantModes.canFind("html") || wantModes.canFind("tui")
            || wantModes.canFind("widgets-html")) && chrome.length == 0)
        stderr.writeln("capture-modes: no Chrome found — html/tui PNGs skipped (HTML still written).");
    if (wantModes.canFind("gui") && !haveXvfb)
        stderr.writeln("capture-modes: no xvfb-run — gui mode skipped.");

    int made;
    foreach (stem; stems)
    {
        const fixture = buildPath(p.fixturesDir, stem ~ ".twoslash.json").absolutePath;
        if (!fixture.exists)
        {
            stderr.writeln("capture-modes: no fixture '", stem, "' — skipping.");
            continue;
        }
        foreach (mode; wantModes)
            switch (mode)
            {
                case "html":
                    made += captureHtml(fixture, outAbs, stem, p.theme, p.hover, chrome);
                    break;
                case "widgets-html":
                    made += captureWidgetsHtml(fixture, outAbs, stem, p.hover, chrome);
                    break;
                case "tui":
                    made += captureTui(hueAbs, fixture, outAbs, stem, p.size, p.hover, chrome);
                    break;
                case "gui":
                    if (haveXvfb)
                        made += captureGui(hueAbs, fixture, outAbs, stem, p.hover);
                    break;
                default:
                    stderr.writeln("capture-modes: unknown mode '", mode, "'");
                    break;
            }
    }
    writeln("capture-modes: wrote ", made, " image(s) to ", p.outDir);
    return 0;
}

/// HTML mode, rendered IN-PROCESS through `sparkles:twoslash`/`sparkles:syntax`
/// (the exact markup `hue --twoslash --html` emits), then screenshot by Chrome.
private int captureHtml(string fixture, string outDir, string stem, string themeName,
    int hover, string chrome) @system
{
    auto html = renderTwoslashPage(fixture, themeName);
    if (html.length == 0)
    {
        stderr.writeln("  html ", stem, ": render failed");
        return 0;
    }
    if (hover >= 0)
        html = forceHtmlHover(html, hover);
    const htmlPath = buildPath(outDir, stem ~ ".html.html");
    write(htmlPath, html);
    return shot(chrome, htmlPath, buildPath(outDir, stem ~ ".html.png"), "760,320");
}

/// Renders a fixture to a self-contained twoslash HTML page (inline theme + overlay
/// stylesheet + the `.twoslash-*` markup) — the same pipeline as `runTwoslashMode`.
private string renderTwoslashPage(string fixture, string themeName) @system
{
    auto twRes = loadTwoslashFile(fixture);
    if (twRes.hasError)
        return "";
    const tw = twRes.value;

    const labels = LabelSet.standard();
    const theme = resolveTheme(builtinThemes.get(themeName, builtinDark), labels);

    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, labels);
    SmallBuffer!HighlightEvent events;
    auto res = highlightInjected(cache, "typescript", tw.code, events);
    if (res.hasError)
        events ~= HighlightEvent.sourceSpan(0, tw.code.length);

    SmallBuffer!char output;
    output ~= "<style>\n";
    writeThemeStylesheet(theme, output);
    writeTwoslashStyles(output);
    output ~= "</style>\n<pre class=\"syn-root twoslash\"><code>";
    renderTwoslashHtml(tw, events[], theme, cache, output);
    output ~= "</code></pre>\n";
    return output[].idup;
}

/// widgets-html mode: renders the SAME `sparkles:ui` widget tree the GUI/TUI paint
/// (via `render_widgets` + `interp/html`) to a self-contained page, then Chrome
/// screenshots it. This is the two-direction parity ground truth: a browser render
/// of the widget spec, to compare the GUI/TUI rasters against (and the generated
/// vs the hand-authored `html` mode).
private int captureWidgetsHtml(string fixture, string outDir, string stem, int hover,
    string chrome) @system
{
    import sparkles.ui.interp.html : writeWidgetHtmlPage;
    import sparkles.ui.style : defaultTwoslashPalette, schemeForBackground;
    import sparkles.ui.widget : WidgetTree;
    import sparkles.twoslash.render_widgets : viewHoverPopup, viewTwoslash;
    import sparkles.base.term_color : RgbColor;
    import std.array : appender;

    auto twRes = loadTwoslashFile(fixture);
    if (twRes.hasError)
    {
        stderr.writeln("  widgets-html ", stem, ": load failed");
        return 0;
    }
    const tw = twRes.value;

    // Match the GUI page colors (catppuccin-mocha) so the palette selects the same
    // dark surface/docs the raster backends resolve.
    const pageFg = RgbColor(0xcd, 0xd6, 0xf4);
    const pageBg = RgbColor(0x1e, 0x1e, 0x2e);
    const pal = defaultTwoslashPalette(schemeForBackground(pageBg));

    WidgetTree tree;
    if (hover >= 0)
    {
        int seen = -1;
        size_t idx = size_t.max;
        foreach (i, ref const n; tw.nodes)
            if (n.type == NodeType.hover && ++seen == hover)
            {
                idx = i;
                break;
            }
        if (idx == size_t.max)
        {
            stderr.writeln("  widgets-html ", stem, ": no hover ", hover);
            return 0;
        }
        // Render JSDoc docs as markdown, matching the GUI (needs the grammar bundle).
        auto registry = GrammarRegistry.fromEnvironment();
        tree = viewHoverPopup(tw, idx, registry);
    }
    else
        tree = viewTwoslash(tw);

    auto w = appender!string;
    writeWidgetHtmlPage(w, tree, pal, pageFg, pageBg, stem);
    const htmlPath = buildPath(outDir, stem ~ ".widgets.html");
    write(htmlPath, w[]);
    return shot(chrome, htmlPath, buildPath(outDir, stem ~ ".widgets.png"), "760,320");
}

/// TUI mode: `HUE_TWOSLASH_TUI_CAPTURE` makes the binary render one cell frame to a
/// styled `<pre>`; Chrome screenshots it. (In-process once the frame renderer moves
/// to a lib with the GUI→widget migration.)
private int captureTui(string hue, string fixture, string outDir, string stem,
    string size, int hover, string chrome)
{
    auto e = environment.toAA;
    e["HUE_TWOSLASH_TUI_CAPTURE"] = hover >= 0 ? format("%s,%s", size, hover) : size;
    auto r = execute([hue, "--twoslash", fixture], e);
    if (r.status != 0)
    {
        stderr.writeln("  tui ", stem, ": hue failed");
        return 0;
    }
    const htmlPath = buildPath(outDir, stem ~ ".tui.html");
    write(htmlPath, r.output);
    return shot(chrome, htmlPath, buildPath(outDir, stem ~ ".tui.png"), "760,320");
}

/// GUI mode: xvfb + `HUE_GUI_SCREENSHOT` (+ `HUE_GUI_HOVER`) write the PNG directly
/// — the one backend that is irreducibly a separate raylib-window process.
private int captureGui(string hue, string fixture, string outDir, string stem, int hover)
{
    const png = stem ~ ".gui.png"; // relative — raylib TakeScreenshot prepends CWD
    auto e = environment.toAA;
    e["HUE_GUI_SCREENSHOT"] = png;
    if (hover >= 0)
        e["HUE_GUI_HOVER"] = format("%s", hover);
    auto pid = spawnProcess(["xvfb-run", "-a", hue, "--gui", "--twoslash", fixture],
        env: e, config: Config.none, workDir: outDir);
    if (pid.wait != 0 || !buildPath(outDir, png).exists)
    {
        stderr.writeln("  gui ", stem, ": no screenshot produced");
        return 0;
    }
    return 1;
}

/// Screenshots `htmlPath` → `pngPath` with headless Chrome. Returns 1 on success.
private int shot(string chrome, string htmlPath, string pngPath, string windowSize)
{
    if (chrome.length == 0)
        return 0;
    auto r = execute([chrome, "--headless=new", "--disable-gpu", "--no-sandbox",
        "--hide-scrollbars", "--force-device-scale-factor=2",
        "--window-size=" ~ windowSize, "--screenshot=" ~ pngPath, "file://" ~ htmlPath]);
    return (r.status == 0 && pngPath.exists) ? 1 : 0;
}

/// Marks the Nth `.twoslash-hover` and injects CSS forcing its popup visible.
private string forceHtmlHover(string html, int n)
{
    enum marker = "<span class=\"twoslash-hover\">";
    string outp;
    int seen = -1;
    size_t cursor;
    while (true)
    {
        const at = indexOfFrom(html, marker, cursor);
        if (at == size_t.max)
            break;
        if (++seen == n)
        {
            outp = html[0 .. at] ~ "<span class=\"twoslash-hover\" data-fh=\"1\">"
                ~ html[at + marker.length .. $];
            break;
        }
        cursor = at + marker.length;
    }
    if (outp.length == 0)
        outp = html; // fewer than n hovers — leave as-is
    enum rule = ".twoslash-hover[data-fh] .twoslash-popup-container" ~
        "{display:inline-flex!important;position:static!important;margin-top:4px!important}";
    return outp.replace("</style>", rule ~ "</style>");
}

private size_t indexOfFrom(string s, string needle, size_t from)
{
    import std.string : indexOf;

    const r = s[from .. $].indexOf(needle);
    return r < 0 ? size_t.max : from + cast(size_t) r;
}

/// The first of `names` found on `PATH` (via the `command` shell builtin), or "".
private string findFirst(string[] names)
{
    foreach (n; names)
    {
        auto r = executeShell("command -v " ~ n);
        if (r.status == 0 && r.output.strip.length)
            return n;
    }
    return "";
}

/// Resolves the tree-sitter grammar bundle from the flake (best effort).
private string nixGrammarPath()
{
    auto r = execute(["nix", "build", ".#ts-grammars", "--no-link", "--print-out-paths"]);
    return r.status == 0 ? r.output.strip : "";
}
