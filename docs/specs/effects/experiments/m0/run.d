#!/usr/bin/env dub
/+ dub.sdl:
    name "effects-m0-probe-runner"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// Execute from this directory. Artifacts go to a caller-selected directory.
import std.algorithm.searching : canFind, count;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;

int main(string[] args)
{
    if (args.length != 2)
    {
        writeln("usage: dub run --single run.d -- /tmp/effects-m0-results");
        return 2;
    }
    const output = args[1];
    mkdirRecurse(output);
    size_t checks;
    foreach (compiler; ["dmd", "ldc2"])
    {
        const versionResult = execute([compiler, "--version"]);
        assert(versionResult.status == 0, versionResult.output);
        write(buildPath(output, compiler ~ "-version.txt"), versionResult.output);
        foreach (optimized; [false, true])
        foreach (inlineBridge; [false, true])
        {
            const label = compiler ~ (optimized ? "-checked" : "-debug")
                ~ (inlineBridge ? "-inline" : "-noinline");
            auto flags = [compiler, "-preview=in", "-preview=dip1000", "-g"];
            if (optimized)
                flags ~= compiler == "dmd" ? ["-O", "-inline"]
                    : ["-O2", "-enable-inlining"];
            else
                flags ~= compiler == "dmd" ? ["-debug"] : ["-d-debug"];
            if (inlineBridge)
                flags ~= compiler == "dmd" ? "-version=InlineBridge"
                    : "-d-version=InlineBridge";
            foreach (debugEscape; [false, true])
            {
                const name = label ~ (debugEscape ? "-escape" : "");
                auto command = flags ~ ["probe.d", "bridge.d",
                    "-of=" ~ buildPath(output, name)];
                if (debugEscape)
                    command ~= compiler == "dmd" ? "-version=DebugEscape"
                        : "-d-version=DebugEscape";
                const compiled = execute(command);
                write(buildPath(output, name ~ "-compile.txt"), compiled.output);
                assert(compiled.status == 0, compiled.output);
                const result = execute([buildPath(output, name)]);
                write(buildPath(output, name ~ "-run.txt"), result.output);
                assert(result.status == 0, result.output);
                assert(result.output.canFind("a=37 b=37 local=4,4 world=8 context=3,2"));
                assert(result.output.canFind("exception=-2 latched=-1"));
                assert(result.output.count("effect:10\n") == 8);
                if (debugEscape)
                    assert(result.output.canFind(optimized ? "debug-world=8" : "debug-world=9"));
                writeln(name, ": PASS");
                ++checks;
            }
            immutable diagnosticNeedles = ["cannot call impure", "currTime", "writeln",
                "no property", "not copyable", "recordable!T",
                "cannot implicitly convert", "cannot implicitly convert"];
            foreach (index, negative; ["DirectImpure", "AmbientClock", "AmbientIo",
                "EscapeHandler", "CopyRow", "SerializeResource",
                "ThrowingHandler", "AllocatingHandler"])
            {
                auto command = flags ~ ["-o-", "-c", "probe.d", "bridge.d",
                    (compiler == "dmd" ? "-version=" : "-d-version=") ~ negative];
                const result = execute(command);
                write(buildPath(output, label ~ "-" ~ negative ~ ".txt"), result.output);
                assert(result.status != 0 && result.output.canFind("Error:"), result.output);
                assert(result.output.canFind(diagnosticNeedles[index]), result.output);
                writeln(label, "-", negative, ": rejected");
                ++checks;
            }
        }
    }
    writeln(checks, " compiler/runtime checks passed; this is not a soundness proof.");
    return 0;
}
