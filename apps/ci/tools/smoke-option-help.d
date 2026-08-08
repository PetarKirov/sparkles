#!/usr/bin/env dub
/+ dub.sdl:
    name "smoke_option_help"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Smoke-test per-option value help against the bundled CLI examples.
 *
 * An option that knows its values answers `--opt=help`, `--opt=?`, `--opt?`,
 * `-o=help` and `-o?` with a screen naming the option and listing them, then
 * exits zero without the program running. The unit tests in
 * `sparkles.core_cli.args.internal` cover the parsing; this covers the whole
 * path — a real binary, built the way Nix builds it, invoked the way a user
 * would.
 *
 * Each case asserts three things: the process exited zero, it printed
 * something, and what it printed names the option asked about. That last
 * check is what catches the interesting regression — help for the *wrong*
 * option, which a bare exit-code check would pass.
 *
 * Run with: `dub run --single smoke-option-help.d`
 * (from anywhere in the repo; `nix` locates the flake).
 */
module smoke_option_help;

import std.algorithm : canFind, map, sum;
import std.array : array, join;
import std.stdio : writeln;
import std.string : strip;

import sparkles.base.styled_template : styledText, styledWriteln;
import sparkles.core_cli.process_utils : runCaptured;

/// One invocation and the option name its output must mention.
struct Case
{
    string[] args;  /// arguments after the binary
    string expect;  /// substring the help screen must contain
}

/// The examples exercised, each with the invocations that cover a kind of
/// option: enumerated values, a bool, and a free-form string.
struct Example
{
    string name;    /// nix attribute + binary name under `bin/`
    Case[] cases;
}

immutable Example[] examples = [
    Example("docker", [
        Case(["run", "--restart=help"], "--restart"),
        Case(["network", "create", "--driver?"], "--driver"),
        Case(["volume", "create", "-d=help"], "-d"),
        Case(["--log-level?"], "--log-level"),
    ]),
    Example("dub", [
        Case(["build", "--build=help"], "--build"),
        Case(["build", "--compiler?"], "--compiler"),
        Case(["init", "-f?"], "-f"),
    ]),
    Example("gh", [
        Case(["repo", "list", "--visibility=help"], "--visibility"),
        Case(["pr", "list", "-s?"], "-s"),
        Case(["pr", "merge", "--merge-method=?"], "--merge-method"),
        Case(["issue", "close", "--reason=help"], "--reason"),
    ]),
    Example("systemctl", [
        Case(["kill", "--kill-whom?"], "--kill-whom"),
        // `-t|--type` is systemctl's own option, so it precedes the subcommand.
        Case(["-t=help", "list-units"], "-t"),
        // Free-form string — the screen describes the shape it accepts.
        Case(["kill", "--signal=help"], "--signal"),
        // Bool — the screen lists the true/false/yes/no spellings.
        Case(["start", "--no-block=help"], "--no-block"),
    ]),
];

int main()
{
    size_t failures;

    foreach (example; examples)
    {
        styledWriteln(i"{bold $(example.name)}");

        const attr = "libs/core-cli/examples/cli/" ~ example.name;
        const built = runCaptured([
            "nix", "build", "--no-link", "--print-out-paths",
            "--option", "warn-dirty", "false",
            ".#examples.core-cli." ~ example.name,
        ]);

        if (!built.succeeded)
        {
            styledWriteln(i"  {red ✗ could not build} $(attr)");
            writeln(built.stderr.strip);
            failures++;
            continue;
        }

        const bin = built.stdout.strip ~ "/bin/" ~ example.name;

        foreach (c; example.cases)
        {
            const invocation = example.name ~ " " ~ c.args.join(" ");
            const result = runCaptured([bin] ~ c.args);
            const output = result.stdout ~ result.stderr;

            if (!result.succeeded)
            {
                styledWriteln(i"  {red ✗} $(invocation) {dim — exit $(result.status)}");
                failures++;
            }
            else if (!output.canFind(c.expect))
            {
                styledWriteln(
                    i"  {red ✗} $(invocation) {dim — output does not mention} $(c.expect)");
                writeln(output.strip);
                failures++;
            }
            else
            {
                styledWriteln(i"  {green ✓} $(invocation)");
            }
        }

        writeln();
    }

    const total = examples.map!(e => e.cases.length).sum;
    if (failures == 0)
        styledWriteln(i"{green ✓} all $(total) per-option help invocations passed");
    else
        styledWriteln(i"{red ✗} $(failures) of $(total) invocations failed");

    return failures == 0 ? 0 : 1;
}
