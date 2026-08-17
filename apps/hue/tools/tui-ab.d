#!/usr/bin/env dub
/+ dub.sdl:
    name "tui_ab"
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// The A/B oracle a behaviour-preserving hue TUI change otherwise lacks.
//
// A terminal application's output IS its frame: the bytes hue writes to the
// tty are the complete rendering, so two builds that paint the same screen
// write the same bytes. That makes a refactor checkable without a screenshot,
// an X server or a human — run both binaries through a pty, compare.
//
//   dub run --single apps/hue/tools/tui-ab.d -- \
//       --old /tmp/hue-before --new apps/hue/build/hue \
//       --file libs/ui/src/sparkles/ui/state.d
//
// Two guards, because both of their failures have happened here and each
// reads as a pass:
//
//   * A capture must be REPRODUCIBLE before it may be compared. hue runs an
//     async git-status worker, and a golden that races it produced two
//     different images from one binary — a difference the tool would then
//     have blamed on the change. Every side is captured `--runs` times and a
//     side that disagrees with itself is a failure, not a diff.
//   * The two binaries must actually DIFFER. `dub build -c no-gui` writes to
//     the same path as the default config, so it is easy to A/B one build
//     against itself and read "byte-identical" as proof of anything.
//
// Exit status: 0 identical, 1 drift (with the first differing offset and its
// neighbourhood), 2 a setup problem — a missing binary, `script`, or a
// non-reproducible capture.
module tui_ab;

import core.thread : Thread;
import core.time : msecs;

import std.algorithm : min;
import std.digest.md : md5Of, toHexString;
import std.file : exists, isFile, read;
import std.format : format;
import std.path : absolutePath;
import std.process : Config, environment, pipeProcess, Redirect, spawnShell, wait;
import std.stdio : File, stderr, writefln, writeln;

import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;

/// CLI surface (parsed by `sparkles:core-cli`, per the D-tooling guideline).
struct Params
{
    @(Option("old|o", description: "The baseline hue binary"))
    string old;

    @(Option("new|n", description: "The changed hue binary"))
    string new_ = "apps/hue/build/hue";

    @(Option("file|f", description: "The file to open in the viewer"))
    string file = "libs/ui/src/sparkles/ui/state.d";

    @(Option("args", description: "Extra arguments, before the file"))
    string extraArgs = "--tui";

    @(Option("cols", description: "Terminal width for the pty"))
    int cols = 100;

    @(Option("rows", description: "Terminal height for the pty"))
    int rows = 40;

    @(Option("keys|k", description: "Keys to send once the frame has settled"))
    string keys = "q";

    @(Option("settle", description: "Milliseconds to wait before sending keys"))
    int settleMs = 2000;

    @(Option("runs|r", description: "Captures per side; they must all agree"))
    int runs = 2;

    @(Option("dump", description: "Write each side's bytes to this prefix"))
    string dumpPrefix;

}

int main(string[] rawArgs)
{
    auto parsed = parseCli!Params(rawArgs, HelpInfo("tui-ab",
        "A/B two hue builds by their TUI frame bytes: a terminal application's "
        ~ "output IS its rendering, so a behaviour-preserving change writes the "
        ~ "same bytes.", null));
    if (!parsed)
        return reportCliError(parsed.error);
    auto p = parsed.value;

    if (!hasScript)
    {
        stderr.writeln("tui-ab: `script` is not on PATH — cannot allocate a pty.");
        return 2;
    }
    if (p.old.length == 0)
    {
        stderr.writeln("tui-ab: --old is required (build the baseline first, "
            ~ "e.g. `git stash`-free: check out the file, build, copy the binary).");
        return 2;
    }
    foreach (bin; [p.old, p.new_])
        if (!bin.exists || !bin.isFile)
        {
            stderr.writefln("tui-ab: no such binary: %s", bin);
            return 2;
        }
    if (!p.file.exists)
    {
        stderr.writefln("tui-ab: no such file to open: %s", p.file);
        return 2;
    }

    // Guard two: one build compared against itself proves nothing, and is the
    // easy mistake because both configs write to the same target path.
    const oldBytes = cast(const(ubyte)[]) read(p.old);
    const newBytes = cast(const(ubyte)[]) read(p.new_);
    if (oldBytes == newBytes)
    {
        stderr.writeln("tui-ab: the two binaries are byte-identical, so this "
            ~ "comparison could not have detected anything. Rebuild one.");
        return 2;
    }
    writefln("binaries differ: old %s (%s bytes), new %s (%s bytes)",
        digest(oldBytes), oldBytes.length, digest(newBytes), newBytes.length);

    ubyte[] oldFrame, newFrame;
    if (!capture(p, p.old, "old", oldFrame))
        return 2;
    if (!capture(p, p.new_, "new", newFrame))
        return 2;

    if (p.dumpPrefix.length)
    {
        import std.file : writeFile = write;

        writeFile(p.dumpPrefix ~ "old.bin", oldFrame);
        writeFile(p.dumpPrefix ~ "new.bin", newFrame);
    }

    if (oldFrame == newFrame)
    {
        writefln("identical: %s bytes, %s", oldFrame.length, digest(oldFrame));
        return 0;
    }
    reportDrift(oldFrame, newFrame);
    return 1;
}

/// Captures one side `p.runs` times, requiring every run to agree. Returns
/// `false` (after explaining) when they do not: an unstable capture cannot be
/// the baseline for anything.
private bool capture(in Params p, string bin, string label, out ubyte[] frame)
{
    ubyte[] first;
    foreach (i; 0 .. (p.runs > 1 ? p.runs : 1))
    {
        auto bytes = runOnce(p, bin);
        if (bytes.length == 0)
        {
            stderr.writefln("tui-ab: %s produced no output — did it fail to start?",
                label);
            return false;
        }
        if (i == 0)
            first = bytes;
        else if (bytes != first)
        {
            stderr.writefln("tui-ab: %s is NOT reproducible — run 1 was %s bytes "
                ~ "(%s), run %s was %s bytes (%s). Something asynchronous is in "
                ~ "the frame (hue's git-status worker is the usual one); pin it "
                ~ "before comparing anything.",
                label, first.length, digest(first), i + 1, bytes.length,
                digest(bytes));
            return false;
        }
    }
    writefln("%s: %s bytes, %s (stable over %s runs)",
        label, first.length, digest(first), p.runs > 1 ? p.runs : 1);
    frame = first;
    return true;
}

/// One pty session: `script` allocates the tty hue insists on, `stty` fixes
/// the grid so the frame is the same size on any developer's terminal, and the
/// keys arrive only once the first frame has settled — a key written before
/// raw mode is set is read by the shell instead.
private ubyte[] runOnce(in Params p, string bin)
{
    const inner = format!"stty cols %s rows %s; %s view %s %s"(
        p.cols, p.rows, absolutePath(bin), p.extraArgs, p.file);
    auto pipes = pipeProcess(["script", "-qec", inner, "/dev/null"],
        Redirect.stdin | Redirect.stdoutToStderr | Redirect.stderr,
        ["COLUMNS": format!"%s"(p.cols), "LINES": format!"%s"(p.rows)],
        Config.none);

    Thread.sleep(p.settleMs.msecs);
    try
    {
        pipes.stdin.write(p.keys);
        pipes.stdin.flush();
    }
    catch (Exception)
    {
        // The child may already have exited; its output is still the frame.
    }
    try
        pipes.stdin.close();
    catch (Exception) {}

    ubyte[] out_;
    foreach (chunk; pipes.stderr.byChunk(4096))
        out_ ~= chunk;
    wait(pipes.pid);
    return out_;
}

private void reportDrift(in ubyte[] a, in ubyte[] b)
{
    stderr.writefln("DRIFT: old %s bytes (%s), new %s bytes (%s)",
        a.length, digest(a), b.length, digest(b));
    size_t at;
    while (at < a.length && at < b.length && a[at] == b[at])
        ++at;
    stderr.writefln("first difference at byte %s", at);
    const from = at > 40 ? at - 40 : 0;
    stderr.writefln("  old: %s", visible(a[from .. min(a.length, at + 40)]));
    stderr.writefln("  new: %s", visible(b[from .. min(b.length, at + 40)]));
}

/// Escape sequences printed as `^[`, so a diff is readable in a log.
private string visible(in ubyte[] bytes)
{
    string s;
    foreach (c; bytes)
    {
        if (c == 0x1b)
            s ~= "^[";
        else if (c < 0x20 || c == 0x7f)
            s ~= format!"\\x%02x"(c);
        else
            s ~= cast(char) c;
    }
    return s;
}

private string digest(in ubyte[] bytes)
    => md5Of(bytes).toHexString()[0 .. 12].idup;

private bool hasScript()
{
    auto pid = spawnShell("command -v script > /dev/null 2>&1");
    return wait(pid) == 0;
}
