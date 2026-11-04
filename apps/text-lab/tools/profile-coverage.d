#!/usr/bin/env dub
/+ dub.sdl:
name "text-lab-profile-coverage"
targetPath "../../../build"
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
+/
/**
Device experiment driver. Install text-lab.apk first, then run:
`dub run --single apps/text-lab/tools/profile-coverage.d -- adb /tmp/coverage 3 420`
Extra arguments after the frame count are passed to text-lab. The installed
debug app must have files/fonts/NotoSans.ttf, as supplied by its font bundle.
Raw traces, worker-time reports, arguments and device conditions are retained.
See docs/libs/ui-app/explanation/font-preview-performance.md.
*/
module profile_coverage;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : sort, sum;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.json : JSONType, parseJSON;
import std.path : buildPath;
import std.process : execute;
import std.stdio : File, stderr;
import std.string : join;

void main(string[] argv)
{
    assert(argv.length >= 3, "usage: profile-coverage <adb> <output-dir> [repetitions=3] [frames=420] [app args...]");
    const adb = argv[1], output = argv[2];
    const repetitions = argv.length > 3 ? argv[3].to!uint : 3;
    const frames = argv.length > 4 ? argv[4].to!uint : 420;
    assert(repetitions && frames > 60);
    mkdirRecurse(output);
    auto summary = File(buildPath(output, "summary.csv"), "w");
    summary.writeln("run,metric,samples,mean_ms,p50_ms,p95_ms,p99_ms,max_ms");
    enum packageName = "dev.petar_kirov.sparkles.text_lab";
    enum appFiles = "/data/user/0/" ~ packageName ~ "/files";
    string call(string[] args)
    {
        const result = execute([adb] ~ args);
        assert(result.status == 0, result.output);
        return result.output;
    }
    write(buildPath(output, "device.txt"), "serial=" ~ call(["get-serialno"])
        ~ "model=" ~ call(["shell", "getprop", "ro.product.model"])
        ~ "soc=" ~ call(["shell", "getprop", "ro.soc.model"])
        ~ "sdk=" ~ call(["shell", "getprop", "ro.build.version.sdk"]));
    write(buildPath(output, "vulkan.json"), call(["shell", "cmd", "gpu", "vkjson"]));
    write(buildPath(output, "display.txt"), call(["shell", "dumpsys", "display"]));
    // A newly installed app may not have been launched to create files yet.
    call(["shell", "run-as", packageName, "mkdir", "-p", "files"]);
    foreach (workload; ["weight", "size"])
        foreach (repetition; 0 .. repetitions)
            foreach (position; 0 .. 3)
            {
                // Rotate order to expose warm-up/thermal/order effects.
                const mode = ["cpu", "edges", "bands"][(position + repetition) % 3];
                const label = workload ~ '-' ~ mode ~ '-' ~ repetition.to!string;
                const directory = buildPath(output, label);
                mkdirRecurse(directory);
                stderr.writeln(label);
                call(["shell", "am", "force-stop", packageName]);
                string[] args = ["--font", appFiles ~ "/fonts/NotoSans.ttf", "--font-size", "12",
                    "--no-loupe", "--settings", "--raster-workers", "4", "--coverage-mode", mode,
                    "--coverage-report", appFiles ~ "/coverage.csv", "--sweep-frames", frames.to!string,
                    "--sweep-mode", workload, "--debug", "gpu-timing", "--debug",
                    "frame-trace=" ~ appFiles ~ "/profile.json"];
                if (argv.length > 5) args ~= argv[5 .. $];
                write(buildPath(directory, "args.txt"), args.join("\n"));
                write(buildPath(directory, "battery.txt"), call(["shell", "dumpsys", "battery"]));
                write(buildPath(directory, "thermal.txt"), call(["shell", "dumpsys", "thermalservice"]));
                call(["push", buildPath(directory, "args.txt"), "/data/local/tmp/text-lab-next.args"]);
                call(["shell", "run-as", packageName, "cp", "/data/local/tmp/text-lab-next.args", "files/next-launch.args"]);
                call(["shell", "run-as", packageName, "rm", "-f", "files/profile.json", "files/coverage.csv"]);
                call(["shell", "am", "start", "-W", "-n", packageName ~ "/android.app.NativeActivity"]);
                const start = MonoTime.currTime;
                bool complete;
                while (MonoTime.currTime - start < 90.seconds)
                {
                    Thread.sleep(250.msecs);
                    // Trace export follows application shutdown's CSV close.
                    if (execute([adb, "shell", "run-as", packageName, "test", "-f", "files/profile.json"]).status == 0)
                    { complete = true; break; }
                    if (MonoTime.currTime - start > 2.seconds)
                        assert(execute([adb, "shell", "pidof", packageName]).status == 0,
                            "App exited without exporting a trace: " ~ label);
                }
                assert(complete, "No completed trace for " ~ label);
                const trace = call(["exec-out", "run-as", packageName, "cat", "files/profile.json"]);
                write(buildPath(directory, "profile.json"), trace);
                write(buildPath(directory, "coverage.csv"),
                    call(["exec-out", "run-as", packageName, "cat", "files/coverage.csv"]));
                double[][string] samples;
                double[] starts;
                foreach (event; parseJSON(trace)["traceEvents"].array)
                {
                    const phase = "ph" in event.object;
                    if (phase is null || phase.str != "X") continue;
                    const frame = "frame" in event["args"].object;
                    if (frame is null || frame.integer < 60) continue;
                    const category = event["cat"].str;
                    const duration = event["dur"];
                    const ms = (duration.type == JSONType.float_ ? duration.floating : cast(double)duration.integer) / 1000;
                    samples[category == "frame" ? "native_frame" : category ~ '_' ~ event["name"].str] ~= ms;
                    if (category == "frame")
                    {
                        const timestamp = event["ts"];
                        starts ~= (timestamp.type == JSONType.float_ ? timestamp.floating : cast(double)timestamp.integer) / 1000;
                    }
                }
                sort(starts);
                foreach (i; 1 .. starts.length) samples["start_interval"] ~= starts[i] - starts[i - 1];
                foreach (metric, values; samples)
                {
                    sort(values);
                    summary.writefln("%s,%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f", label, metric, values.length,
                        values.sum / values.length, values[$ / 2], values[($ - 1) * 95 / 100],
                        values[($ - 1) * 99 / 100], values[$ - 1]);
                }
                summary.flush();
            }
}
