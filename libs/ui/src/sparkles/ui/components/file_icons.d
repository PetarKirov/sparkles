/**
File-type icons (hue `XPL6`): the Nerd Font glyph and conventional brand colour
of a file, by its name, and the folder pair a directory shows in place of a
disclosure marker — the vscode-icons / snacks-explorer look.

One table, so a file looks the same in every tree that shows one: hue's
explorer, and the fileset explorer.
*/
module sparkles.ui.components.file_icons;

import sparkles.base.term_color : RgbColor;

/// A file-type icon: the glyph, with its trailing space, and its colour.
struct FileIcon
{
    string glyph;  ///
    RgbColor fg;   ///
}

/// The colour every folder glyph is drawn in: the conventional folder amber.
enum RgbColor folderFg = RgbColor(0xdc, 0xb6, 0x7a);

/// The folder glyph of an open or closed directory.
string folderGlyph(bool open) @safe pure nothrow @nogc
    => open ? "\U0000F115 " : "\U0000F114 "; //  open /  closed

/// The icon of the file `name`, from its extension.
FileIcon fileIcon(scope const(char)[] name) @safe pure nothrow @nogc
{
    const(char)[] ext;
    foreach_reverse (i, ch; name)
        if (ch == '.')
        {
            ext = name[i + 1 .. $];
            break;
        }

    switch (ext)
    {
        case "d", "di":          return FileIcon("\U0000E7AF ", RgbColor(0xb0, 0x39, 0x31));
        case "md", "markdown":   return FileIcon("\U0000E609 ", RgbColor(0x51, 0x9a, 0xba));
        case "json":             return FileIcon("\U0000E60B ", RgbColor(0xcb, 0xcb, 0x41));
        case "js", "mjs", "jsx": return FileIcon("\U0000E781 ", RgbColor(0xf1, 0xe0, 0x5a));
        case "ts", "tsx":        return FileIcon("\U0000E628 ", RgbColor(0x31, 0x78, 0xc6));
        case "sh", "bash", "zsh", "fish":
            return FileIcon("\U0000E795 ", RgbColor(0x89, 0xe0, 0x51));
        case "nix":              return FileIcon("\U000F1105 ", RgbColor(0x7e, 0xba, 0xe4));
        case "py":               return FileIcon("\U0000E606 ", RgbColor(0x35, 0x72, 0xa5));
        case "rs":               return FileIcon("\U0000E7A8 ", RgbColor(0xde, 0xa5, 0x84));
        case "c", "h":           return FileIcon("\U0000E61E ", RgbColor(0x65, 0x9b, 0xd3));
        case "cpp", "cc", "cxx", "hpp":
            return FileIcon("\U0000E61D ", RgbColor(0x65, 0x9b, 0xd3));
        case "go":               return FileIcon("\U0000E627 ", RgbColor(0x00, 0xad, 0xd8));
        case "html", "htm":      return FileIcon("\U0000E736 ", RgbColor(0xe4, 0x4d, 0x26));
        case "css":              return FileIcon("\U0000E749 ", RgbColor(0x56, 0x3d, 0x7c));
        case "glsl", "vert", "frag", "geom", "comp", "tesc", "tese":
            return FileIcon("\U0000E6A2 ", RgbColor(0x56, 0xb6, 0xc2));
        case "spvasm", "spirv":
            return FileIcon("\U0000E6A2 ", RgbColor(0x7e, 0xba, 0xe4));
        case "toml", "yaml", "yml", "ini", "cfg", "conf", "sdl":
            return FileIcon("\U0000E615 ", RgbColor(0x6d, 0x80, 0x86));
        case "lock":             return FileIcon("\U0000F023 ", RgbColor(0x6d, 0x80, 0x86));
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "ico":
            return FileIcon("\U0000F1C5 ", RgbColor(0xa0, 0x74, 0xc4));
        case "pdf":              return FileIcon("\U0000F1C1 ", RgbColor(0xb3, 0x0b, 0x00));
        case "zip", "gz", "xz", "zst", "tar", "7z":
            return FileIcon("\U0000F1C6 ", RgbColor(0xff, 0xb8, 0x6c));
        case "txt":              return FileIcon("\U0000F15C ", RgbColor(0x89, 0xa8, 0xc8));
        default:                 return FileIcon("\U0000F016 ", RgbColor(0x6d, 0x80, 0x86));
    }
}

/// A name's last extension picks its icon; a name without one gets the
/// generic file.
@("ui.file_icons.fileIcon")
@safe pure nothrow @nogc
unittest
{
    assert(fileIcon("dub.sdl").glyph == fileIcon("x.toml").glyph, "config files share the gear");
    assert(fileIcon("a.tar.gz").glyph == fileIcon("b.zip").glyph);
    assert(fileIcon("LICENSE").glyph == "\U0000F016 ");
    assert(fileIcon("flake.nix").fg == RgbColor(0x7e, 0xba, 0xe4));
    assert(folderGlyph(true) != folderGlyph(false));
}
