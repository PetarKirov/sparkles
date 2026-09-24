/**
The `dmd-fmt` command — M5's CI surface (`--check` with an exit code) and
the batch entry point. Build with the `cli` configuration:

---
dub build :dmd-fmt --config=cli
---

Usage: `dmd-fmt [--check|--inplace] FILE...` (no files: stdin → stdout).
Exit codes: 0 formatted/clean, 1 `--check` found differences, 2 usage or
I/O errors, 3 the formatter failed its own verification.

$(B Nothing is written that has not been verified.) Every result goes
through M1's [sparkles.dmd_fmt.verify.verifyFormat] before it reaches stdout
or a file, and a failure is refusal — not a warning printed beside output
already on disk. The check is the whole safety story of a tool that edits
your source in place, and it is worth the second lex: a printer defect that
dropped a braced block shipped for weeks precisely because the CLI formatted
without ever asking the verifier.

Exit code 3 is deliberately distinct from 1: `--check` returning 1 means
your file is not formatted, and 3 means the formatter is broken. A CI job
must be able to tell those apart.
*/
module sparkles.dmd_fmt.cli;

version (DmdFmtCli):

import sparkles.dmd_fmt.config : configFor, FormatConfig;
import sparkles.dmd_fmt.printer : formatText;
import sparkles.dmd_fmt.verify : formatVerified;

/// Format `source`, or return null when the result does not verify — having
/// said why on stderr. `name` is what the message calls the input.
private string formatOrRefuse(string source, in FormatConfig cfg, string name) @system
{
    import std.stdio : stderr;

    const got = formatVerified(
        (const(char)[] s) => cast(const(char)[]) formatText(s, cfg), source);
    if (got.ok)
        return got.text;
    stderr.writefln("dmd-fmt: refusing to write %s: %s", name, got.error);
    stderr.writeln("dmd-fmt: this is a formatter bug, not a problem with your code");
    return null;
}

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
                stderr.writeln("exit: 0 clean, 1 --check found differences, "
                    ~ "2 usage/IO, 3 failed verification");
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

    if (!files.length)
    {
        // stdin: discover config from the working directory.
        const cfg = configFor("stdin.d");
        string source;
        foreach (chunk; stdin.byChunk(64 * 1024))
            source ~= cast(const(char)[]) chunk;
        const formatted = formatOrRefuse(source, cfg, "stdin");
        if (formatted is null)
            return 3;
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

    int unformatted, unverified;
    foreach (file; files)
    {
        if (!file.exists)
        {
            stderr.writefln("dmd-fmt: no such file: %s", file);
            return 2;
        }
        const source = cast(string) read(file);
        // One bad file does not abandon the batch: the rest are still
        // formattable, and a run over a tree should report every refusal it
        // has rather than the first.
        const formatted = formatOrRefuse(source, configFor(file), file);
        if (formatted is null)
        {
            unverified++;
            continue;
        }
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
    if (unverified)
        return 3;
    return unformatted ? 1 : 0;
}
