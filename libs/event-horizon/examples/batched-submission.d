#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_batched_submission"
    dependency "sparkles:event-horizon" path="../../.."
    platforms "linux" "osx"
    targetPath "build"
    // Platform default, or `-c libkqueue` for the Linux peer path.
    // `targetType "executable"` is required once any configuration is
    // declared (otherwise a single-file package silently builds a library).
    configuration "default-backend" {
        targetType "executable"
    }
    configuration "libkqueue" {
        targetType "executable"
        subConfiguration "sparkles:event-horizon" "libkqueue"
    }
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The submission contract, from the outside (SPEC §5.2, O27) — three
 * properties a caller can rely on regardless of which backend is underneath,
 * demonstrated with `OpPollAdd` so nothing here needs a buffer.
 *
 * $(OL
 *   $(LI $(B Submissions batch.) Eight ops submitted before the loop runs
 *     reach the kernel together, in the same call that collects their
 *     completions, and come back in $(I one) `runOnce`. On io_uring that is
 *     eight SQEs and one `io_uring_enter`; on kqueue it is an eight-entry
 *     change list riding down with the `kevent(2)` that waits — the shape
 *     libdispatch's `_dispatch_kq_drain` uses, and the reason a steady-state
 *     loop does not pay a register-then-wait pair per operation.)
 *   $(LI $(B A rejected submission is a completion.) Submitting against a
 *     closed descriptor $(I succeeds) — the kernel has not seen it yet, so
 *     submission cannot know — and the refusal arrives later as an ordinary
 *     completion carrying `-errno` (`EBADF` on Darwin, `EFAULT` on
 *     libkqueue 2.7). A `false` out of the backend's
 *     `trySubmit` means one thing only: a submission resource is full, flush
 *     and retry. Conflating the two makes the loop retry an `EBADF` forever.)
 *   $(LI $(B Cancelling before the first wait still works.) The submission
 *     and the cancellation that undoes it travel in one ordered queue, so a
 *     nine-second timer cancelled before any wait unparks immediately with
 *     `-ECANCELED` instead of racing its own registration and staying armed.)
 * )
 *
 * ---
 * dub run --single batched-submission.d -b checked               # platform default
 * dub run --single batched-submission.d -b checked -c libkqueue  # kqueue via libkqueue
 * ---
 *
 * `-c libkqueue` needs the sparkles nix devshell (`libs "kqueue"`). Prints
 * `SKIP:` and exits 0 if the backend cannot open.
 */
module event_horizon_batched_submission;

import core.stdc.errno : EBADF, ECANCELED, EFAULT;
import core.time : Duration, msecs, seconds;

import core.sys.posix.unistd : close, pipe, write;

import sparkles.base.logger : LogLevel, info, initLogger, warning;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.loop : DefaultLoop, RunStatus;
import sparkles.event_horizon.op : Completion, OpHandle, OpPollAdd, PollEvents;

/// Backend this build resolved to (for ok/SKIP messages).
version (EventHorizonLibkqueue)
    enum backend = DefaultBackend.stringof ~ " (mheily/libkqueue)";
else
    enum backend = DefaultBackend.stringof;

enum batch = 8;

/// What the callbacks report back.
struct Tally
{
    uint ready;    /// poll completions that said "readable"
    int lastError; /// the most recent negative `res`
    uint calls;    /// callbacks run, of any outcome
}

extern (D) void onPoll(void* ctx, ref Completion done) nothrow @nogc
{
    auto t = cast(Tally*) ctx;
    ++t.calls;
    if (done.res < 0)
        t.lastError = done.res;
    else if (done.res & PollEvents.readable)
        ++t.ready;
}

int main()
{
    initLogger(LogLevel.info);

    DefaultLoop loop;
    auto created = DefaultLoop.create(loop);
    if (created.hasError)
    {
        warning(i"SKIP: $(backend) unavailable (errno $(created.error.errnoValue)) — $(created.error.context)");
        return 0;
    }
    scope (exit) loop.destroy();

    // ── 1. eight submissions, one turn ──────────────────────────────────────

    // Eight pipes, each already holding a byte, so every registration is
    // satisfiable the moment the kernel sees it. Readiness is therefore not
    // what is being timed here — the number of loop turns is.
    int[2][batch] pipes;
    foreach (ref p; pipes)
    {
        if (pipe(p) != 0)
        {
            warning(i"SKIP: pipe() failed");
            return 0;
        }
        immutable ubyte one = 1;
        cast(void) write(p[1], &one, 1);
    }
    scope (exit)
        foreach (ref p; pipes)
        {
            close(p[0]);
            close(p[1]);
        }

    Tally polls;
    foreach (ref p; pipes)
    {
        auto h = loop.submit(OpPollAdd(p[0], PollEvents.readable, false),
            &onPoll, &polls);
        assert(!h.hasError, "eight ops fit in any backend's submission queue");
    }

    uint turns;
    while (polls.calls < batch && turns < 4)
    {
        const st = loop.runOnce(2.seconds);
        assert(!st.hasError);
        ++turns;
    }
    assert(polls.ready == batch, "every poll completed readable");
    assert(turns == 1,
        "all eight registrations rode down with the wait that collected them");
    info(i"batched: $(batch) submissions completed in $(turns) loop turn");

    // ── 2. a rejected submission comes back as a completion ─────────────────

    int[2] doomed;
    if (pipe(doomed) != 0)
    {
        warning(i"SKIP: pipe() failed");
        return 0;
    }
    close(doomed[0]);
    close(doomed[1]); // a plausible descriptor number that now names nothing

    Tally rejected;
    auto bad = loop.submit(OpPollAdd(doomed[0], PollEvents.readable, false),
        &onPoll, &rejected);
    assert(!bad.hasError,
        "submission reports queued, not accepted — the kernel has not looked yet");

    turns = 0;
    while (rejected.calls == 0 && turns < 4)
    {
        cast(void) loop.runOnce(2.seconds);
        ++turns;
    }
    assert(rejected.calls == 1, "the refusal was delivered");
    // Darwin reports EBADF. libkqueue 2.7.0's kn_create substitutes EFAULT
    // when the filter leaves errno unset, and hides that EV_ERROR behind a
    // wait-timeout of 0 — which the backend harvests. Either way this is a
    // completion, not a submit-time `false`.
    assert(rejected.lastError == -EBADF || rejected.lastError == -EFAULT,
        "…as a completion carrying the backend's own errno");
    info(i"rejected: a closed fd surfaced as res=$(rejected.lastError)");

    // ── 3. cancel before the first wait ─────────────────────────────────────

    // A timer far longer than this program's patience: if the cancellation
    // were reordered against the registration it undoes, the wait below would
    // sit here for nine seconds and the deadline assert would catch it.
    Tally slept;
    auto timer = loop.submitAfter(9.seconds, &onPoll, &slept);
    assert(!timer.hasError);
    assert(!loop.cancel(timer.value).hasError);

    turns = 0;
    while (slept.calls == 0 && turns < 4)
    {
        const st = loop.runOnce(2.seconds);
        assert(!st.hasError && st.value != RunStatus.timedOut,
            "a cancelled op must not leave the loop waiting on its original deadline");
        ++turns;
    }
    assert(slept.calls == 1 && slept.lastError == -ECANCELED,
        "the cancelled timer unparked with -ECANCELED");
    info(i"cancelled: a 9s timer unparked in $(turns) turn with -ECANCELED");

    info(i"ok: submission contract holds on $(backend)");
    return 0;
}
