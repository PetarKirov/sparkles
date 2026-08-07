#!/usr/bin/env dub
/+ dub.sdl:
    name "ui_app_tui_loop_demo"
    dependency "sparkles:ui-app" path="../../.."
    subConfiguration "sparkles:ui-app" "tui"
    platforms "linux"
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The M17 gate in miniature, self-verifying and headless: the event-horizon
 * terminal loop arm (`runTui`) driven end to end under a PTY that
 * event-horizon itself spawned (`spawnPty`, SPEC §13.3).
 *
 * Two roles in one binary:
 *
 * - `--child`: a tiny full-screen app on `runTui` — it paints a counter,
 *   advances it per keypress, and quits on `q`. Its loop is the SPEC §15.3
 *   TUI shape: input and SIGWINCH fibers feeding a channel, the app in the
 *   root fiber, ONE ring wait for everything.
 * - parent (default): spawns itself with `--child` as a session leader on a
 *   fresh PTY, scripts three keypresses through the master, drains the
 *   child's screen output, reaps it in-ring, and verifies the exit report —
 *   the loop arm and the proc v2 machinery proving each other.
 *
 * SKIPs (exit 0) if io_uring or a PTY is unavailable.
 */
module ui_app_tui_loop_demo;

import core.lifetime : move;
import std.format : format;
import std.stdio : stderr, writefln, writeln;

import sparkles.base.smallbuffer : SmallBuffer;

int main(string[] args)
{
    if (args.length > 1 && args[1] == "--child")
        return childMain();
    return parentMain(args[0]);
}

// ── the child: a minimal app on the event-horizon loop arm ──────────────────

int childMain()
{
    import sparkles.input : Event, KeyEvent, isEndOfInput, match;
    import sparkles.ui.canvas : DrawOp, OpKind;
    import sparkles.ui.geometry : Rect;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.tui_loop : TuiHost, runTui;

    int presses;
    int frames;
    bool sawAsyncLoop;

    const ok = runTui!(
        (ref TuiHost h) {
            ++frames;
            sawAsyncLoop = h.asyncLoop;
            // One textRun per frame: the counter line the parent can see.
            h.ops() ~= DrawOp(kind: OpKind.textRun,
                rect: Rect(0, 0, 20, 1), text: "presses");
        },
        (ref TuiHost h, in Event e) {
            e.match!(
                (in KeyEvent k) {
                    if (k.ch == 'q')
                        h.quit();
                    else
                        ++presses;
                },
                (in _) {},
            );
            if (e.isEndOfInput)
                h.quit();
        })(RunConfig(title: "demo"));

    // The report lands on stderr AFTER the session restores, so the parent
    // can assert on it without scraping the alt screen.
    stderr.writefln("demo: frames=%d presses=%d async=%d", frames, presses,
        sawAsyncLoop ? 1 : 0);
    return ok && presses == 3 ? 0 : 1;
}

// ── the parent: drive the child through a PTY it spawned ────────────────────

int parentMain(string self)
{
    import sparkles.event_horizon.io : read, write;
    import sparkles.event_horizon.live : spawnPty, wait;
    import sparkles.event_horizon.proc : ExitStatus;
    import sparkles.event_horizon.sched : Sched;

    Sched sched;
    if (Sched.create(sched).hasError)
    {
        writeln("SKIP: io_uring unavailable");
        return 0;
    }
    scope (exit) sched.destroy();

    bool verified;
    bool skipped;
    auto r = sched.run(() {
        auto spawned = spawnPty([self, "--child"], 80, 24);
        if (spawned.hasError)
        {
            skipped = true;
            return;
        }
        auto child = spawned.value;

        // Drain the child's terminal output; type only AFTER its first frame
        // appears. Raw-mode entry uses TCSAFLUSH, which discards input queued
        // before the mode switch — keys sent at spawn time would be eaten by
        // the flush, and the child would wait forever (found the hard way:
        // this demo hanging is exactly that race).
        SmallBuffer!(ubyte, 4096) screen;
        bool typed;
        for (;;)
        {
            SmallBuffer!(ubyte, 512) buf;
            buf.length = 512;
            auto got = read(child.ptyMaster, move(buf));
            buf = move(got.buf);
            if (got.res.hasError || got.res.value == 0)
                break; // EIO/EOF: the child is gone
            screen ~= buf[][0 .. got.res.value];

            if (!typed && contains(cast(const(char)[]) screen[], "presses"))
            {
                // Script: three counting keypresses, then the quit key. One
                // write — the child's assembler and channel do the rest.
                typed = true;
                SmallBuffer!(ubyte, 8) keys;
                keys ~= cast(const(ubyte)[]) "abcq";
                auto sent = write(child.ptyMaster, move(keys));
                assert(!sent.res.hasError);
            }
        }

        auto st = wait(sched, child);
        assert(st.hasValue);
        child.ptyMaster.close();

        // The child's own exit code carries the assertion (3 presses, clean
        // quit); the screen must show the counter line was painted.
        const painted = contains(cast(const(char)[]) screen[], "presses");
        verified = st.value.ok && painted;
        if (!verified)
            writefln("child: signaled=%s code=%d painted=%s screen=%d bytes\n--- screen tail ---\n%s",
                st.value.signaled, st.value.code, painted, screen.length,
                cast(const(char)[]) screen[][screen.length < 400 ? 0 : screen.length - 400 .. screen.length]);
    });
    assert(!r.hasError);
    if (skipped)
    {
        writeln("SKIP: no PTY available");
        return 0;
    }

    if (verified)
        writeln("ok: runTui drove the child app end to end under a spawned PTY");
    else
        writeln("FAILED");
    return verified ? 0 : 1;
}

bool contains(const(char)[] hay, const(char)[] needle) @safe
{
    if (needle.length == 0 || hay.length < needle.length)
        return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle)
            return true;
    return false;
}
