#!/usr/bin/env dub
/+ dub.sdl:
    name "capture-modes"
+/
// Twoslash QA capture harness: renders every fixture in all three `hue --twoslash`
// backends — GUI (raylib), TUI (terminal cell grid), and HTML — to PNGs in one
// directory, so a reviewer can eyeball parity across modes without hand-driving
// each backend. Speeds up the GUI↔TUI↔HTML parity QA loop.
//
// It drives the built `hue` binary plus two external tools:
//   * a headless Chrome (`google-chrome-stable`/`chromium`) turns the HTML and the
//     TUI-frame HTML into PNGs;
//   * `xvfb-run` gives the raylib GUI an off-screen display for its screenshot.
// Missing tools degrade gracefully (that mode is skipped with a note).
//
// The TUI is captured headlessly via hue's `HUE_TWOSLASH_TUI_CAPTURE` hook (one
// frame → styled `<pre>` → Chrome), and the GUI via its `HUE_GUI_SCREENSHOT` hook;
// `--hover N` opens the Nth hover popup in every mode (GUI `HUE_GUI_HOVER`, TUI
// selIdx, HTML forced `:hover` via injected CSS).
//
// Run from the repo root (after `dub build :hue`):
//   dub run --single apps/hue/tools/capture-modes.d -- --out /tmp/parity
//   dub run --single apps/hue/tools/capture-modes.d -- --hover 0 08-jsdoc 02-query
//
// Substantial QA logic in D per the repo guideline (not a shell script).
module capture_modes;

import std.algorithm : canFind, filter, map, sort;
import std.array : array, join, replace;
import std.file : dirEntries, exists, mkdirRecurse, readText, write, SpanMode;
import std.format : format;
import std.getopt : defaultGetoptPrinter, getopt;
import std.path : absolutePath, baseName, buildPath, stripExtension;
import std.process : Config, environment, execute, executeShell, spawnProcess, wait;
import std.stdio : stderr, writeln;
import std.string : split, strip;

int main(string[] args)
{
    string outDir = "capture-out";
    string fixturesDir = "libs/twoslash/examples/fixtures";
    string hueBin = "apps/hue/build/hue";
    string modes = "gui,tui,html";
    string size = "100x30";
    int hover = -1;

    auto help = getopt(args,
        "out|o", "Output directory for the PNGs (default: capture-out)", &outDir,
        "fixtures|f", "Fixtures directory (default: libs/twoslash/examples/fixtures)", &fixturesDir,
        "hue", "Path to the built hue binary (default: apps/hue/build/hue)", &hueBin,
        "modes|m", "Comma list of modes: gui,tui,html (default: all)", &modes,
        "size|s", "TUI capture grid, <cols>x<rows> (default: 100x30)", &size,
        "hover", "Open the Nth hover popup in every mode (default: -1 = resting)", &hover,
    );
    if (help.helpWanted)
    {
        defaultGetoptPrinter("capture-modes — twoslash GUI/TUI/HTML QA screenshots\n" ~
            "Positional args: specific fixture stems (e.g. 08-jsdoc); default: all.", help.options);
        return 0;
    }

    if (!hueBin.exists)
    {
        stderr.writeln("capture-modes: hue binary not found at '", hueBin,
            "' — run `dub build :hue` first (or pass --hue).");
        return 1;
    }

    const wantModes = modes.split(",").map!strip.array;
    const hueAbs = hueBin.absolutePath;
    outDir.mkdirRecurse;
    const outAbs = outDir.absolutePath;

    // The fixture stems to render: positional args (if any) else every fixture.
    string[] stems = args[1 .. $];
    if (stems.length == 0)
        stems = dirEntries(fixturesDir, "*.twoslash.json", SpanMode.shallow)
            .map!(e => e.name.baseName.replace(".twoslash.json", "")).array;
    stems.sort();

    // External-tool discovery (degrade gracefully when one is missing).
    const chrome = findFirst(["google-chrome-stable", "google-chrome", "chromium", "chromium-browser"]);
    const haveXvfb = findFirst(["xvfb-run"]).length > 0;

    // Grammar bundle: honour the env, else resolve it from the flake once.
    auto env = environment.toAA;
    if ("SPARKLES_TS_GRAMMAR_PATH" !in env)
    {
        const g = nixGrammarPath();
        if (g.length)
            env["SPARKLES_TS_GRAMMAR_PATH"] = g;
    }

    if (wantModes.canFind("html") || wantModes.canFind("tui"))
        if (chrome.length == 0)
            stderr.writeln("capture-modes: no Chrome found — html/tui PNGs skipped (HTML files still written).");
    if (wantModes.canFind("gui") && !haveXvfb)
        stderr.writeln("capture-modes: no xvfb-run — gui mode skipped.");

    int made;
    foreach (stem; stems)
    {
        const fixture = buildPath(fixturesDir, stem ~ ".twoslash.json").absolutePath;
        if (!fixture.exists)
        {
            stderr.writeln("capture-modes: no fixture '", stem, "' — skipping.");
            continue;
        }
        foreach (mode; wantModes)
        {
            final switch (mode)
            {
                case "html":
                    made += captureHtml(hueAbs, fixture, outAbs, stem, hover, chrome, env);
                    break;
                case "tui":
                    made += captureTui(hueAbs, fixture, outAbs, stem, size, hover, chrome, env);
                    break;
                case "gui":
                    if (haveXvfb)
                        made += captureGui(hueAbs, fixture, outAbs, stem, hover, env);
                    break;
            }
        }
    }
    writeln("capture-modes: wrote ", made, " image(s) to ", outDir);
    return 0;
}

/// HTML mode: `hue --twoslash --html` → a page; force the Nth hover popup open via
/// injected CSS when requested; Chrome screenshots it.
private int captureHtml(string hue, string fixture, string outDir, string stem,
    int hover, string chrome, string[string] env)
{
    const htmlPath = buildPath(outDir, stem ~ ".html.html");
    auto r = execute([hue, "--twoslash", "--html", fixture], env);
    if (r.status != 0)
    {
        stderr.writeln("  html ", stem, ": hue failed");
        return 0;
    }
    auto html = r.output;
    if (hover >= 0)
        html = forceHtmlHover(html, hover);
    write(htmlPath, html);
    return shot(chrome, htmlPath, buildPath(outDir, stem ~ ".html.png"), "760,320");
}

/// TUI mode: `HUE_TWOSLASH_TUI_CAPTURE` renders one frame to a styled `<pre>`;
/// Chrome screenshots it.
private int captureTui(string hue, string fixture, string outDir, string stem,
    string size, int hover, string chrome, string[string] env)
{
    auto e = env.dup;
    e["HUE_TWOSLASH_TUI_CAPTURE"] = hover >= 0 ? format("%s,%s", size, hover) : size;
    const htmlPath = buildPath(outDir, stem ~ ".tui.html");
    auto r = execute([hue, "--twoslash", fixture], e);
    if (r.status != 0)
    {
        stderr.writeln("  tui ", stem, ": hue failed");
        return 0;
    }
    write(htmlPath, r.output);
    return shot(chrome, htmlPath, buildPath(outDir, stem ~ ".tui.png"), "760,320");
}

/// GUI mode: xvfb + `HUE_GUI_SCREENSHOT` (+ `HUE_GUI_HOVER`) write the PNG directly.
private int captureGui(string hue, string fixture, string outDir, string stem,
    int hover, string[string] env)
{
    const png = stem ~ ".gui.png"; // relative — raylib TakeScreenshot prepends CWD
    auto e = env.dup;
    e["HUE_GUI_SCREENSHOT"] = png;
    if (hover >= 0)
        e["HUE_GUI_HOVER"] = format("%s", hover);
    // Run inside outDir so the relative screenshot lands there.
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
    // Tag the (n+1)-th hover token, then a rule shows its popup unconditionally.
    size_t idx;
    int seen = -1;
    string marker = "<span class=\"twoslash-hover\">";
    auto pos = html;
    string outp;
    size_t cursor;
    while (true)
    {
        const at = indexOfFrom(html, marker, cursor);
        if (at == size_t.max)
            break;
        seen++;
        if (seen == n)
        {
            outp = html[0 .. at] ~ "<span class=\"twoslash-hover\" data-fh=\"1\">"
                ~ html[at + marker.length .. $];
            break;
        }
        cursor = at + marker.length;
    }
    if (outp.length == 0)
        outp = html; // fewer than n hovers — leave as-is
    const rule = ".twoslash-hover[data-fh] .twoslash-popup-container" ~
        "{display:inline-flex!important;position:static!important;margin-top:4px!important}";
    return outp.replace("</style>", rule ~ "</style>");
}

private size_t indexOfFrom(string s, string needle, size_t from)
{
    import std.string : indexOf;

    const r = s[from .. $].indexOf(needle);
    return r < 0 ? size_t.max : from + cast(size_t) r;
}

/// The first of `names` found on `PATH` (via `command -v`), or "".
private string findFirst(string[] names)
{
    foreach (n; names)
    {
        auto r = executeShell("command -v " ~ n); // `command` is a shell builtin
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
