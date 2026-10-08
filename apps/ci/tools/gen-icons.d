#!/usr/bin/env dub
/+ dub.sdl:
    name "gen_icons"
    targetPath "build"
+/
/**
 * Generates `libs/ui/src/sparkles/ui/icons.d` (design-system `GLY4`): the
 * Nerd Font icons the toolkit names, each read from the release's own
 * `glyphnames.json` rather than typed in by hand.
 *
 * The list below is curated: an icon joins it when a component draws it.
 * Every name is checked against the file, so a renamed or removed icon fails
 * here instead of drawing tofu. Run from the repository root, in the dev
 * shell, which exports the pinned file:
 *
 *     dub run --single apps/ci/tools/gen-icons.d
 *
 * `sparkles.ui.icons`' own test checks the checked-in table against the same
 * file, so a table that drifts from the release fails there too.
 */
module gen_icons;

import std.algorithm.iteration : map;
import std.array : join, split;
import std.conv : to;
import std.file : readText, write;
import std.format : format;
import std.json : JSONType, parseJSON;
import std.process : environment;
import std.stdio : stderr, writeln;
import std.string : capitalize;
import std.uni : toUpper;

/// The icons the toolkit draws, by their `glyphnames.json` name.
immutable string[] curated = [
    // Status marks (`GLY3`): `sparkles.ui.glyphs.Mark`.
    "fa-check", "fa-xmark", "fa-triangle_exclamation", "fa-circle_info",
    "fa-circle_o", "fa-spinner", "fa-minus",
    // Markdown callouts and blocks: `sparkles.source_view.markdown`.
    "md-information_outline", "md-lightbulb_outline", "md-comment_alert_outline",
    "md-alert_outline", "md-alert_octagon_outline", "md-checkbox_outline",
    "md-checkbox_blank_outline", "md-image_outline", "md-vector_square",
    "md-numeric_1_circle_outline", "md-numeric_2_circle_outline",
    "md-numeric_3_circle_outline", "md-numeric_4_circle_outline",
    "md-numeric_5_circle_outline", "md-numeric_6_circle_outline",
    // Processes and hosts: `sparkles.terminal_view.process_info`.
    "dev-terminal", "dev-dlang", "md-nix", "md-ssh", "md-monitor", "md-web",
    "md-email",
];

/// `md-numeric_1_circle_outline` → `mdNumeric1CircleOutline`.
string identifierOf(string name)
{
    string r;
    foreach (i, part; name.split!(c => c == '-' || c == '_'))
        r ~= i == 0 ? part : part.capitalize;
    return r;
}

int main(string[] args)
{
    const source = args.length > 1 ? args[1] : environment.get("SPARKLES_NERD_FONT_GLYPHNAMES", "");
    if (source.length == 0)
    {
        stderr.writeln("gen-icons: no glyphnames.json; enter `nix develop` or pass its path");
        return 2;
    }
    auto json = parseJSON(readText(source));
    const ver = json["METADATA"]["version"].str;

    string body_;
    foreach (name; curated)
    {
        const entry = name in json.object;
        if (entry is null)
        {
            stderr.writeln("gen-icons: ", name, " is not in Nerd Fonts ", ver);
            return 1;
        }
        const code = (*entry)["code"].str;
        body_ ~= format("    %s = '\\U%08X', /// `%s`\n", identifierOf(name), code.to!uint(16), name);
    }

    const sources = curated.map!(n => "\n    `" ~ n ~ "`,").join;
    const text = format(`/**
The Nerd Font icons the toolkit draws (design-system ` ~ "`GLY4`" ~ `), by name.

$(B Generated) by ` ~ "`apps/ci/tools/gen-icons.d`" ~ ` from Nerd Fonts %s's
` ~ "`glyphnames.json`" ~ `; do not edit. An icon joins the curated list in the
generator when a component draws it. A Nerd Font is baseline on GUI and Web
and the configured ` ~ "`nerdFont`" ~ ` capability on a terminal, so a component draws
these through the glyph ladder, which substitutes where the target has none.
*/
module sparkles.ui.icons;

/// The Nerd Fonts release the table was generated from.
enum string nerdFontsVersion = "%s";

/// One code point per icon; each member's comment is its ` ~ "`glyphnames.json`" ~ ` name.
enum Icon : dchar
{
%s}

/// The ` ~ "`glyphnames.json`" ~ ` name of each $(LREF Icon) member, in declaration order.
static immutable string[] iconSourceNames = [%s
];
`, ver, ver, body_, sources);
    write("libs/ui/src/sparkles/ui/icons.d", text);
    writeln("gen-icons: wrote ", curated.length, " icons from Nerd Fonts ", ver);
    return 0;
}
