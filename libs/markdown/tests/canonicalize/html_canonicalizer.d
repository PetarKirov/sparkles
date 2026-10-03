import std.file : readText;
import std.stdio : stderr, write;

import sparkles.markdown.testing : canonicalizeHtml;

int main(string[] args)
{
    if (args.length < 2)
    {
        stderr.writeln("Usage: html_canonicalizer.d <html-file>");
        return 2;
    }

    auto canonical = canonicalizeHtml(readText(args[1]));
    write(canonical);
    return 0;
}
