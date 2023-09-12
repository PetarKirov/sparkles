#!/usr/bin/env dub

/+ dub.sdl:
name "color"
dependency "sparkles:core-cli" version="*"
targetPath "build"
+/

import sparkles.core_cli.term_style;
import std;

alias stb = stylizedTextBuilder;

alias Seq(T...) = T;

alias nonColorStyles = Seq!(Style.bold, Style.dim, Style.italic, Style.underline, Style.inverse, Style.strikethrough);
static immutable colorStyles = [EnumMembers!Style[9 .. $]];

string allNonColorTextOptions()
{
    string text;
    static foreach(i; 0 .. nonColorStyles.length)
        text ~= nonColorStyles[i].stringof.stylize(nonColorStyles[i], true) ~ " ";
    return text;
}

void main()
{
    import sparkles.core_cli.ui.table;
    enum text = "asd";
    string[][] table = new string[][colorStyles.length];
    foreach (i, color; colorStyles)
        static foreach(j; 0 .. nonColorStyles.length)
            table[i] ~= text
                .stylize(nonColorStyles[j])
                .stylize(color);

    drawTable(table).writeln;
}
