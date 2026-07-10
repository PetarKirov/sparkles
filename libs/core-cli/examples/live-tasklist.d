#!/usr/bin/env dub
/+ dub.sdl:
    name "live-tasklist"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

// ci: build-only

// The live-rendering stack (`ui/live` + `ui/tasklist` + `runStreaming`): a
// `LiveRegion` repaints a block in place (DEC 2026 synchronized frames, static
// channel for lines graduating into scrollback, non-tty degradation to a plain
// transition log); a `TaskReporter` drives a checklist through it, streaming a
// child process's output into the running task's bounded tail pane. Animated,
// so `ci` only builds this; run it in a terminal — and pipe it through `cat`
// to see the escape-free non-tty transition log.

module live_tasklist_example;

import core.thread : Thread;
import core.time : msecs;

import sparkles.core_cli.process_utils : runStreaming;
import sparkles.core_cli.term_caps : detectTermCaps;
import sparkles.core_cli.ui.live : stdoutLiveRegion;
import sparkles.core_cli.ui.tasklist : TaskReporter;
import sparkles.core_cli.ui.theme : makeTheme;

void main()
{
    const theme = makeTheme(detectTermCaps());
    auto region = stdoutLiveRegion();
    scope (exit)
        region.finish();
    auto tasks = TaskReporter(&region, theme);

    // Register everything up front so the pending rows show the plan.
    const fetch = tasks.add("fetch dependencies");
    const build = tasks.add("build (streams output into the tail pane)");
    const lint = tasks.add("lint");
    const publish = tasks.add("publish");

    tasks.start(fetch);
    foreach (i; 0 .. 8)
    {
        tasks.tick(); // spinner animation between events
        Thread.sleep(80.msecs);
    }
    tasks.succeed(fetch);

    // A real child process: each output line lands in the bounded tail pane
    // (last 4 lines) under the running row, and pulses the spinner.
    tasks.start(build);
    runStreaming(["sh", "-c",
        "for i in $(seq 1 12); do echo compiling module $i; sleep 0.15; done"],
        (scope const(char)[] line) { tasks.output(build, line); });
    tasks.succeed(build);

    tasks.start(lint);
    Thread.sleep(300.msecs);
    tasks.fail(lint, "3 warnings\nunused import in app.d\nshadowed variable in io.d");

    tasks.skip(publish, "blocked by lint");
}
