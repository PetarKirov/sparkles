/**
 * Shared helpers for the `examples/valgrind-*.d` probes.
 *
 * Deliberately one directory *above* `examples/`: `ci --example-files` globs
 * `docs/research/sanitizers/examples/*.d`, and a git pathspec's `*` matches
 * `/` too — so anything under `examples/`, including a subdirectory, is picked
 * up and run as an example. This file has no `main` and no `dub.sdl` header,
 * so that would simply fail. Living here keeps it out of the glob while the
 * examples pull it in with `sourceFiles "../valgrind_helpers.d"`.
 */
module valgrind_helpers;

import core.time : Duration, seconds;

/// How long a liveness probe waits for valgrind to instrument `true`.
enum valgrindProbeDeadline = 20.seconds;

/**
 * Whether valgrind can actually *instrument* a program here — not merely
 * whether it answers `--version`.
 *
 * The launcher answering a version string proves only that it is on PATH. On
 * CircleCI's AWS machine executor (kernel 6.14-aws) valgrind 3.26 answers
 * `--version`, emits its full XML preamble, and then wedges: the
 * `memcheck-amd64-` process sleeps in `do_wait` forever. A version-only probe
 * reads that as healthy and sends an example into a hang instead of the skip
 * it was designed to take.
 *
 * So instrument something trivial under a deadline. `true` is the cheapest
 * guest there is, and a valgrind that cannot finish it in
 * $(LREF valgrindProbeDeadline) cannot run these examples either. The deadline
 * is what turns a wedged valgrind into a SKIP rather than a hang —
 * `std.process.execute` has no timeout, which is why this goes through
 * `executeMonitored` instead.
 *
 * Params:
 *   reason = set to a human-readable explanation when the result is `false`
 *
 * Returns: `true` when valgrind ran `true` to a clean exit within the deadline.
 */
bool valgrindCanInstrument(out string reason)
{
    import std.format : format;
    import sparkles.core_cli.process_utils :
        ChildStdin, executeMonitored, isInPath;

    if (!isInPath("valgrind"))
    {
        reason = "valgrind not found on PATH";
        return false;
    }

    // `ChildStdin.empty` so the probe cannot inherit — or block on — the
    // terminal of whatever ran it. The sample interval is deliberately coarse:
    // this wants the deadline, not a resource trace, and every sample walks
    // /proc.
    const probe = executeMonitored(
        ["valgrind", "--quiet", "--tool=memcheck", "true"],
        2.seconds, null, ChildStdin.empty, valgrindProbeDeadline);

    if (probe.timedOut)
    {
        reason = format!("valgrind could not instrument `true` within %s"
            ~ " (present but not usable on this host)")(valgrindProbeDeadline);
        return false;
    }
    if (probe.status != 0)
    {
        reason = format!"`valgrind true` exited %d"(probe.status);
        return false;
    }
    return true;
}
