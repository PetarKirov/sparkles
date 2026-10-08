#!/usr/bin/env dub
/+ dub.sdl:
    name "gen_site_css"
    targetPath "build"
    dependency "sparkles:docs" path="../../.."
    dependency "sparkles:ui" path="../../.."
+/
/**
Generates `docs/.vitepress/theme/spk.css` (design-system `WEB3`): the docs
site's `--spk-*` properties, emitted from its two theme files rather than
written by hand. `custom.css` maps VitePress's variables from these and
authors no color of its own.

Run from the repository root after editing a theme file:

    dub run --single apps/ci/tools/gen-site-css.d

`sparkles.docs.assets`' drift test emits the same sheet and compares it with
the committed one, so a theme edit without a rerun fails there.
*/
module gen_site_css;

import std.file : write;
import std.stdio : stderr, writeln;

import sparkles.docs.assets : siteStylesheet, siteStylesheetPath, siteThemePaths;

int main()
{
    auto css = siteStylesheet(".");
    if (css.hasError)
    {
        stderr.writeln("gen-site-css: ", css.error.path, ": ", css.error.message);
        return 1;
    }
    write(siteStylesheetPath, css.value);
    writeln("gen-site-css: wrote ", siteStylesheetPath, " from ", siteThemePaths[0], " and ",
        siteThemePaths[1]);
    return 0;
}
