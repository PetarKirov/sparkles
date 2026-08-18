/**
The `dmd-fmt` command — M5's CI surface (`--check` with an exit code) and
the batch entry point. Build with the `cli` configuration:

---
dub build :dmd-fmt --config=cli
---

Usage: `dmd-fmt [--check|--inplace] FILE...` (no files: stdin → stdout).
Exit codes: 0 formatted/clean, 1 `--check` found differences, 2 usage or
I/O errors.
*/
module sparkles.dmd_fmt.cli;

version (DmdFmtCli):

import sparkles.dmd_fmt.config : FormatConfig;
import sparkles.dmd_fmt.printer : formatText;

int main(string[] args) @system
{
    import std.file : exists, read, write;
    import std.stdio : stderr, stdin, stdout;

    bool check, inplace;
    string[] files;
    foreach (arg; args[1 .. $])
    {
        switch (arg)
        {
            case "--check": check = true; break;
            case "--inplace", "-i": inplace = true; break;
            case "--help", "-h":
                stderr.writeln("usage: dmd-fmt [--check|--inplace] FILE...");
                return 0;
            default:
                if (arg.length && arg[0] == '-')
                {
                    stderr.writefln("dmd-fmt: unknown option %s", arg);
                    return 2;
                }
                files ~= arg;
        }
    }
    if (check && inplace)
    {
        stderr.writeln("dmd-fmt: --check and --inplace are mutually exclusive");
        return 2;
    }

    FormatConfig cfg; // M7: discovered per file from .editorconfig

    if (!files.length)
    {
        string source;
        foreach (chunk; stdin.byChunk(64 * 1024))
            source ~= cast(const(char)[]) chunk;
        const formatted = formatText(source, cfg);
        if (check)
            return formatted == source ? 0 : 1;
        stdout.rawWrite(formatted);
        return 0;
    }

    if (files.length > 1 && !check && !inplace)
    {
        stderr.writeln("dmd-fmt: multiple files need --check or --inplace");
        return 2;
    }

    int unformatted;
    foreach (file; files)
    {
        if (!file.exists)
        {
            stderr.writefln("dmd-fmt: no such file: %s", file);
            return 2;
        }
        const source = cast(string) read(file);
        const formatted = formatText(source, cfg);
        if (check)
        {
            if (formatted != source)
            {
                stderr.writefln("dmd-fmt: not formatted: %s", file);
                unformatted++;
            }
            continue;
        }
        if (inplace)
        {
            if (formatted != source)
                write(file, formatted);
            continue;
        }
        stdout.rawWrite(formatted);
    }
    return unformatted ? 1 : 0;
}
