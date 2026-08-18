/**
Formatting configuration — decision D5/D6 defaults, plus (M7) discovery via
`.editorconfig` honoring dfmt's key names for migration.
*/
module sparkles.dmd_fmt.config;

/// The options the v1 formatter honors. Defaults follow dfmt where dfmt has
/// an opinion (soft max 80, hard max 120) and the D style elsewhere.
struct FormatConfig
{
    /// Columns per indentation level (`indent_size`).
    int indentSize = 4;
    /// Indent with tabs (`indent_style = tab`).
    bool useTabs = false;
    /// Columns one tab advances (`tab_width`).
    int tabWidth = 4;
    /// The width the greedy engine wraps toward
    /// (`dfmt_soft_max_line_length`; the greedy engine has one width, and
    /// the soft limit is the one wrapping targets — see D3/D6).
    int softMaxLineLength = 80;
    /// Accepted for dfmt compatibility (`max_line_length`); v1 keeps it for
    /// a future soft/hard split and does not act on it.
    int maxLineLength = 120;
    /// Most consecutive blank lines preserved (runs collapse — M4).
    int maxBlankLines = 2;
    /// Guarantee a single trailing newline (`insert_final_newline`).
    bool insertFinalNewline = true;
}
