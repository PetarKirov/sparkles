#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_msg_ring"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — cross-ring messaging (`IORING_OP_MSG_RING`, Linux 5.18).
 *
 * `MSG_RING` lets one ring post a u64 cookie straight into *another* ring's
 * completion queue. It is the in-kernel wakeup/handoff primitive that powers
 * multi-threaded designs: a worker holding ring A can wake a peer on ring B
 * (often pinned to another core) without any syscall, eventfd, or shared lock —
 * the kernel synthesises a CQE on the destination ring directly.
 *
 * This example creates TWO `Uring` instances in a single process. On ring A it
 * submits `prepMsgRing(ringB.fd, 0, MESSAGE, 0)`: the SQE targets ring B's file
 * descriptor and carries the payload that becomes B's CQE `user_data`. We reap
 * ring A's own send-completion (status 0 = delivered), then wait on ring B and
 * assert it received an unsolicited CQE whose `user_data == MESSAGE`.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.18 — Ring-fd registration, msg-ring, linked-file (May 2022)".
 *
 * Run with: `dub run --single msg-ring.d`
 *
 * Portability: prints a `SKIP:` line and exits 0 if io_uring is unavailable, or
 * if the running kernel is older than 5.18 (no `MSG_RING` op). Demonstrates the
 * feature and prints an `ok:` line on a 5.18+ kernel.
 */
module io_uring_msg_ring;

import during;

import std.stdio : writefln, stderr;

int main()
{
    // The u64 that ring A pushes into ring B's completion queue. On the target
    // ring it surfaces as the CQE's `user_data`, so the receiver can dispatch on
    // it exactly like a locally-submitted op's cookie.
    enum ulong message = 0x5151_5151_DEAD_BEEF;

    // Two independent rings in one process. In a real design these would belong
    // to different worker threads (often on different cores); MSG_RING is the
    // wakeup edge between them.
    Uring ringA, ringB;

    if (ringA.setup(8) < 0)
    {
        writefln("SKIP: io_uring_setup failed — io_uring unavailable on this host");
        return 0;
    }
    if (ringB.setup(8) < 0)
    {
        writefln("SKIP: io_uring_setup failed for second ring — io_uring unavailable");
        return 0;
    }

    // Feature gate: MSG_RING arrived in 5.18. On older kernels probe() reports it
    // unsupported (and a submitted SQE would complete with -EINVAL); skip cleanly.
    auto probe = ringA.probe();
    if (cast(bool)probe && !probe.isSupported(Operation.MSG_RING))
    {
        writefln("SKIP: IORING_OP_MSG_RING unsupported on this kernel (needs Linux 5.18+)");
        return 0;
    }

    // Post the message from ring A into ring B. `prepMsgRing(fd, len, data, flags)`:
    //   fd   = the *destination* ring's fd (ringB.fd) — that is how the kernel
    //          knows which ring's CQ to push into,
    //   len  = a value handed to the target as its CQE `res` (0 here),
    //   data = the payload delivered as the target CQE's `user_data`.
    enum ulong sendCookie = 0xA;
    ringA.putWith!((ref SubmissionEntry e, int targetFd, ulong data) {
        e.prepMsgRing(targetFd, 0, data, 0);
        e.user_data = sendCookie;
    })(ringB.fd, message);

    const submitted = ringA.submit(1);
    if (submitted < 0)
    {
        stderr.writefln("ring A submit failed: errno %d", -submitted);
        return 1;
    }

    // Reap ring A's *own* completion for the send. A 5.18 kernel that recognises
    // the op but cannot deliver returns -EINVAL/-EOPNOTSUPP here — treat that as
    // "feature unsupported" and skip rather than fail.
    ringA.wait(1);
    const sendRes = ringA.front.res;
    const sendEcho = ringA.front.user_data;
    ringA.popFront();

    if (sendRes == -EINVAL || sendRes == -EOPNOTSUPP || sendRes == -ENOSYS)
    {
        writefln("SKIP: IORING_OP_MSG_RING rejected (errno %d) — needs Linux 5.18+", -sendRes);
        return 0;
    }
    if (sendRes < 0)
    {
        stderr.writefln("MSG_RING send completed with error: errno %d", -sendRes);
        return 1;
    }
    if (sendEcho != sendCookie)
    {
        stderr.writefln("ring A user_data mismatch: expected 0x%X, got 0x%X", sendCookie, sendEcho);
        return 1;
    }

    // Now ring B must observe an unsolicited CQE — one we never submitted on B —
    // carrying the payload from A. This is the whole point: a cross-ring wakeup.
    ringB.wait(1);
    const recvData = ringB.front.user_data;
    const recvRes = ringB.front.res;
    ringB.popFront();

    if (recvData != message)
    {
        stderr.writefln("ring B got wrong payload: expected 0x%X, got 0x%X", message, recvData);
        return 1;
    }

    writefln(
        "ok: MSG_RING delivered 0x%X from ring A (send res=%d) into ring B's CQ (res=%d) — cross-ring wakeup with no syscall on B",
        recvData, sendRes, recvRes);
    return 0;
}

// errno constants used for the feature-unsupported gate above.
private enum int EINVAL = 22;
private enum int ENOSYS = 38;
private enum int EOPNOTSUPP = 95;
