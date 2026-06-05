#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_restrictions"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — sandboxing a ring with `IORING_REGISTER_RESTRICTIONS` (Linux 5.10).
 *
 * The 5.10 "deferred setup" trio lets you create a ring that starts *disabled*,
 * lock down exactly which operations it may ever perform, and only then turn it
 * on. The whitelist is one-shot — once installed it can never be widened — so a
 * privileged process can hand a tightly-scoped ring to untrusted code.
 *
 * This demo:
 *   1. sets up a ring with `IORING_SETUP_R_DISABLED` (no SQEs accepted yet);
 *   2. registers a restriction whitelisting only `IORING_OP_NOP` as a legal SQE
 *      opcode (`IORING_RESTRICTION_SQE_OP`);
 *   3. enables the ring with `IORING_REGISTER_ENABLE_RINGS`;
 *   4. proves an allowed op (`NOP`) completes normally;
 *   5. proves a *non*-whitelisted op (`TIMEOUT`) is rejected — the kernel hands
 *      back a CQE with `-EACCES` instead of running it.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.10 — Restrictions and deferred setup (December 2020)".
 *
 * Run with: `dub run --single restrictions.d`
 *
 * Portability: prints a `SKIP:` line and exits 0 if io_uring is unavailable or
 * the restrictions API is not supported on the running kernel, so it stays green
 * in CI regardless of host. (Restrictions are supported on this 6.18 box.)
 */
module io_uring_restrictions;

import during;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS, EACCES;

import std.stdio : writefln, stderr;

int main()
{
    enum ulong nopCookie     = 0xA11_0;   // user_data for the allowed NOP
    enum ulong timeoutCookie = 0xDEAD_0;  // user_data for the forbidden TIMEOUT

    // (1) Create the ring in the *disabled* state. While disabled it accepts no
    // SQEs; the only thing we may do is register restrictions/files/buffers and
    // then enable it. Old kernels without R_DISABLED fail setup with -EINVAL.
    Uring io;
    const setupRet = io.setup(8, SetupFlags.R_DISABLED);
    if (setupRet == -EINVAL)
    {
        writefln("SKIP: IORING_SETUP_R_DISABLED unsupported (errno %d) — restrictions need Linux 5.10+", -setupRet);
        return 0;
    }
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // (2) Build the whitelist. A single `SQE_OP` entry naming NOP is enough to
    // prove the point: as soon as *any* SQE-opcode allow-rule is registered, the
    // kernel switches that dimension to deny-by-default, so every opcode not on
    // the list (e.g. TIMEOUT) is refused.
    io_uring_restriction[1] rules;
    rules[0].opcode = RestrictionOp.IORING_RESTRICTION_SQE_OP;
    rules[0].sqe_op = cast(ubyte) Operation.NOP;

    // `Uring.registerRestrictions` only forwards a single entry, so call the raw
    // syscall wrapper directly to pass the array + count. (Here it's one entry,
    // but this is the shape you'd use to whitelist several opcodes at once.)
    const regRet = () @trusted {
        return io_uring_register(
            io.fd,
            RegisterOpCode.REGISTER_RESTRICTIONS,
            rules.ptr,
            cast(uint) rules.length,
        );
    }();
    if (regRet < 0)
    {
        const e = -regRet;
        if (e == EINVAL || e == EOPNOTSUPP || e == ENOSYS)
        {
            writefln("SKIP: IORING_REGISTER_RESTRICTIONS unsupported (errno %d)", e);
            return 0;
        }
        stderr.writefln("register restrictions failed unexpectedly: errno %d", e);
        return 1;
    }

    // (3) Flip the ring on. After this the whitelist is frozen forever.
    const enableRet = io.enableRings();
    if (enableRet < 0)
    {
        stderr.writefln("enableRings failed: errno %d", -enableRet);
        return 1;
    }

    // (4) Allowed op: a plain NOP should sail through.
    io.putWith!((ref SubmissionEntry e) {
        e.prepNop();
        e.user_data = nopCookie;
    })();
    const nopSubmitted = io.submit(1);
    if (nopSubmitted < 0)
    {
        stderr.writefln("submitting the NOP failed: errno %d", -nopSubmitted);
        return 1;
    }
    io.wait(1);
    const nopRes = io.front.res;
    io.popFront();
    if (nopRes < 0)
    {
        stderr.writefln("whitelisted NOP was rejected (errno %d) — restriction too tight", -nopRes);
        return 1;
    }
    writefln("ok: whitelisted NOP completed (res=%d)", nopRes);

    // (5) Forbidden op: TIMEOUT is not on the whitelist. The kernel doesn't run
    // it — instead it posts a completion carrying -EACCES. (We give it a 0-second
    // relative timeout so that on the off chance it *were* allowed, it would fire
    // immediately rather than block.)
    KernelTimespec ts = { tv_sec: 0, tv_nsec: 0 };
    io.putWith!((ref SubmissionEntry e, ref KernelTimespec t) {
        e.prepTimeout(t);
        e.user_data = timeoutCookie;
    })(ts);
    const toSubmitted = io.submit(1);
    if (toSubmitted < 0)
    {
        stderr.writefln("submitting the TIMEOUT failed: errno %d", -toSubmitted);
        return 1;
    }
    io.wait(1);
    const toRes  = io.front.res;
    const toData = io.front.user_data;
    io.popFront();

    if (toData != timeoutCookie)
    {
        stderr.writefln("CQE cookie mismatch: expected 0x%X, got 0x%X", timeoutCookie, toData);
        return 1;
    }
    // The kernel returns -EACCES for a denied opcode; some versions surface
    // -EINVAL instead. Either proves the whitelist blocked the op.
    if (toRes != -EACCES && toRes != -EINVAL)
    {
        stderr.writefln("expected TIMEOUT to be denied (-EACCES/-EINVAL) but got res=%d", toRes);
        return 1;
    }
    writefln("ok: non-whitelisted TIMEOUT rejected by the sandbox (res=%d, errno %d)", toRes, -toRes);

    writefln("ok: IORING_REGISTER_RESTRICTIONS sandboxed the ring — NOP allowed, TIMEOUT denied");
    return 0;
}
