#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_resize_rings"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — grow a *live* ring with `IORING_REGISTER_RESIZE_RINGS` (Linux 6.13).
 *
 * Before 6.13 a ring's SQ/CQ sizes were fixed at `io_uring_setup` time: to use a
 * bigger ring you had to tear the old one down and build a new one, losing any
 * in-flight requests. `IORING_REGISTER_RESIZE_RINGS` lifts that limit — the kernel
 * allocates fresh SQ/CQ memory at the requested sizes, atomically swaps it in
 * (preserving in-flight requests), and `during`'s `resizeRings` re-`mmap`s the rings
 * to the new regions while keeping the *same* ring file descriptor.
 *
 * Kernel precondition (the non-obvious bit): the resize path requires the ring to be
 * a single, deferred-taskrun issuer — i.e. set up with `IORING_SETUP_SINGLE_ISSUER |
 * IORING_SETUP_DEFER_TASKRUN`. That guarantee lets the kernel swap the ring memory
 * without racing a concurrent submitter. A plain ring (no flags) is rejected with
 * `-EINVAL` even on a 6.13+ kernel, so we set those flags at setup time.
 *
 * What this example does:
 *   1. sets up a deliberately tiny ring (8 SQ entries),
 *   2. resizes it up to 32 SQ / 64 CQ entries via `io.resizeRings(newParams)`,
 *   3. asserts the kernel now *reports* the larger SQ/CQ capacity (`io.params`), and
 *   4. proves the ring is still live by filling the enlarged submission queue with
 *      more `NOP`s than the original 8-deep SQ could ever hold, then submitting them
 *      (the kernel accepting 9+ queued SQEs is only possible because the SQ grew).
 *
 * The resize register op returns `-EINVAL` on kernels older than 6.13 (the opcode is
 * unknown there), in which case we print `SKIP:` and exit 0.
 *
 * Note on scope: we deliberately verify the resize via the *submission* side (SQ
 * depth + a successful `submit`) rather than reaping the post-resize completions.
 * `during` 0.5.0's `resizeRings` re-`mmap`s the rings but does not re-sync its cached
 * CQ head/tail bookkeeping, so reading CQEs back through `front`/`popFront` right
 * after a resize is unreliable in this library version. The kernel feature itself —
 * growing a live ring — is exercised and asserted here regardless.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "6.13 — Ring resize, mem regions, hybrid iopoll".
 *
 * Run with: `dub run --single resize-rings.d`
 *
 * Portability: if the host has no `io_uring` at all, or the running kernel predates
 * 6.13, the program prints a `SKIP:` line and exits 0 so CI stays green.
 */
module io_uring_resize_rings;

import during;

import core.stdc.errno : EINVAL, EOPNOTSUPP, ENOSYS;

import std.stdio : writefln, stderr;

int main()
{
    // Start small on purpose: an 8-entry SQ. `SINGLE_ISSUER | DEFER_TASKRUN` is the
    // kernel-required mode for in-place resize (see the header). `setup` rounds the
    // size to a power of two and fills the kernel-reported sizes into `io.params`.
    Uring io;
    const setupRet = io.setup(8, SetupFlags.SINGLE_ISSUER | SetupFlags.DEFER_TASKRUN);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host",
            -setupRet);
        return 0;
    }

    const uint oldSq = io.params.sq_entries;
    const uint oldCq = io.params.cq_entries;

    // Build the target geometry. `resizeRings` reads `sq_entries`/`cq_entries` as the
    // *requested* sizes; the kernel writes back what it actually allocated and the new
    // mmap offsets (`sq_off`/`cq_off`), which `during` then uses to re-map the rings.
    //
    // Leave `flags` zeroed: the resize only changes ring *geometry*, and the kernel
    // rejects (-EINVAL) a params struct whose `flags` carries anything outside the
    // resize-relevant set.
    SetupParameters newParams;
    newParams.sq_entries = 32;
    newParams.cq_entries = 64;

    const resizeRet = io.resizeRings(newParams);
    if (resizeRet < 0)
    {
        const e = -resizeRet;
        // -EINVAL: pre-6.13 kernels don't know REGISTER_RESIZE_RINGS (opcode 33).
        // -EOPNOTSUPP/-ENOSYS: register path disabled/unimplemented.
        if (e == EINVAL || e == EOPNOTSUPP || e == ENOSYS)
        {
            writefln("SKIP: IORING_REGISTER_RESIZE_RINGS unsupported (errno %d) — needs Linux 6.13+",
                e);
            return 0;
        }
        stderr.writefln("resizeRings failed unexpectedly: errno %d", e);
        return 1;
    }

    // After a successful resize `io.params` reflects the new (kernel-allocated) sizes.
    const uint gotSq = io.params.sq_entries;
    const uint gotCq = io.params.cq_entries;

    if (gotSq < 32 || gotCq < 64)
    {
        stderr.writefln("resize did not grow the rings: sq %u->%u (want >=32), cq %u->%u (want >=64)",
            oldSq, gotSq, oldCq, gotCq);
        return 1;
    }

    // The re-mapped SQ must expose the larger capacity too.
    if (io.capacity < 32)
    {
        stderr.writefln("SQ capacity after resize is %u, expected >=32", cast(uint) io.capacity);
        return 1;
    }

    // Prove the ring is still live on the larger geometry: queue more NOPs than the
    // ORIGINAL 8-deep SQ could ever have held. If the SQ had not actually grown,
    // `io.full` would trip at the old depth and we could not queue this many.
    enum uint toQueue = 20; // > oldSq (8), <= gotSq (32)
    uint queued;
    foreach (i; 0 .. toQueue)
    {
        if (io.full)
            break;
        io.putWith!((ref SubmissionEntry e, ulong tag) {
            e.prepNop();
            e.user_data = tag;
        })(cast(ulong) i);
        queued++;
    }

    if (queued < toQueue)
    {
        stderr.writefln("enlarged SQ only accepted %u/%u SQEs — resize did not take effect",
            queued, toQueue);
        return 1;
    }

    // Hand the batch to the kernel. A successful submit on the resized ring confirms
    // the swapped-in SQ memory and SQE array are wired up correctly.
    const submitted = io.submit(queued);
    if (submitted < 0)
    {
        stderr.writefln("submit on resized ring failed: errno %d", -submitted);
        return 1;
    }
    if (submitted != queued)
    {
        stderr.writefln("submit accepted %d of %u queued SQEs on the resized ring",
            submitted, queued);
        return 1;
    }

    writefln("ok: resized live ring SQ %u->%u, CQ %u->%u; enlarged SQ accepted+submitted %u NOPs",
        oldSq, gotSq, oldCq, gotCq, submitted);
    return 0;
}
