// Ghostty-free presentation types shared by the markdown-preview model and its
// painters. Split out of `gui_ansi.d` so the preview model (`gui_preview.d`) and
// the terminal painter (`preview_ansi.d`) compile into the raylib-/ghostty-free
// `no-gui` build: only `decodeAnsi` (the off-screen libghostty-vt bridge) still
// lives in `gui_ansi.d` and is pulled in solely by the GUI build.
module ansi_model;

import sparkles.base.term_color : RgbColor;

/// Neutral text-attribute bits shared by the preview presentation model
/// (`gui_preview.PreviewRun`), the ANSI decoder (`gui_ansi`), and the painters
/// (`gui.d` maps them onto `sparkles.raylib_text.TextStyle`; `preview_ansi` onto
/// SGR).
enum Attr : ubyte
{
    bold          = 1 << 0,
    italic        = 1 << 1,
    underline     = 1 << 2,
    strikethrough = 1 << 3,
}

/// A maximal run of same-styled cells on one line. `fgDefault`/`bgDefault` mark
/// a cell that used the terminal *default* color (SGR 39/49 or never set): the
/// layout substitutes the theme's page fg/bg so ` ```ansi ` blocks stay
/// theme-consistent. `text` is owned (GC) UTF-8.
struct AnsiSpan
{
    string text;
    RgbColor fg;
    RgbColor bg;
    bool fgDefault;
    bool bgDefault;
    ubyte attrs;
}

/// One decoded line: its styled spans, left to right.
struct AnsiLine
{
    AnsiSpan[] spans;
}
