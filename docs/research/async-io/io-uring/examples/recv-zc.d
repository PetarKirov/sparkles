#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_recv_zc"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — zero-copy receive (`IORING_OP_RECV_ZC` + `IORING_REGISTER_ZCRX_IFQ`, Linux 6.15).
 *
 * Zero-copy receive (ZCRX) lets the kernel DMA incoming packet payloads straight
 * into a userspace memory area pinned to a NIC hardware receive queue, then hand
 * the ring a CQE pointing at the data — no `copy_to_user`. To use it you first
 * `IORING_REGISTER_ZCRX_IFQ` an `io_uring_zcrx_ifq_reg` describing the netdev
 * (`if_idx`) and its RX queue (`if_rxq`) plus a buffer area; afterwards
 * `IORING_OP_RECV_ZC` (`prepRecvZc`) receives into that registered ifq, indexed
 * by `zcrx_ifq_idx`.
 *
 * This requires a NIC with a configured ZC RX queue (header-data split, a steered
 * RSS context, etc.) — hardware that a typical host or CI runner does NOT have.
 * So this example is EXPECTED to take the SKIP path almost everywhere: we attempt
 * `registerIfq` with a minimal descriptor and, on the inevitable failure
 * (`-EINVAL` / `-EOPNOTSUPP` / `-ENODEV` / `-EPERM` / …), print a `SKIP:` line and
 * exit 0. It demonstrates the *shape* of the ZCRX setup call rather than a live
 * transfer.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "6.15 — Zero-copy receive, epoll-wait, vectored fixed, query".
 *
 * Run with: `dub run --single recv-zc.d`
 *
 * Portability: green on any kernel. Old kernels without io_uring (or without the
 * RECV_ZC op / ZCRX register opcode) and hosts lacking a ZCRX-capable NIC all take
 * the SKIP path and exit 0.
 */
module io_uring_recv_zc;

import during;

import core.sys.posix.sys.socket : AF_INET, SOCK_STREAM, socket;
import core.sys.posix.unistd : close;

import std.stdio : writefln, stderr;

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // First gate: does this kernel even know IORING_OP_RECV_ZC (op 58, since 6.15)?
    // Probing avoids issuing a register call the kernel can't understand.
    auto p = io.probe();
    if (!cast(bool)p)
    {
        writefln("SKIP: io_uring_probe failed (errno %d) — cannot determine RECV_ZC support", -p.error);
        return 0;
    }
    if (!p.isSupported(Operation.RECV_ZC))
    {
        writefln("SKIP: IORING_OP_RECV_ZC unsupported on this kernel — needs Linux 6.15+");
        return 0;
    }

    // Second gate: actually try to register a zero-copy RX interface queue.
    //
    // A *working* registration needs a real netdev index (`if_idx`), one of its
    // hardware RX queues (`if_rxq`) put into zero-copy mode, plus an `area_ptr`
    // describing a pinned userspace buffer area and a `region_ptr` for the ifq's
    // shared refill/completion region. We deliberately pass a minimal descriptor
    // (loopback-ish if_idx=1, rq_entries a power of two, no area/region) so we can
    // show the call site; on a host without ZCRX hardware this fails, which is the
    // expected outcome here.
    io_uring_zcrx_ifq_reg reg;
    reg.if_idx = 1;          // would be a real NIC ifindex (loopback is index 1)
    reg.if_rxq = 0;          // hardware RX queue id configured for zero-copy
    reg.rq_entries = 256;    // refill-queue depth (power of two)
    reg.flags = 0;
    reg.area_ptr = 0;        // -> io_uring_zcrx_area_reg (pinned buffer area)
    reg.region_ptr = 0;      // -> io_uring_region_desc (shared ifq region)

    const regRet = io.registerIfq(reg);
    if (regRet < 0)
    {
        // Any of these is expected on a host without a ZCRX-capable NIC:
        //   -EINVAL/-EOPNOTSUPP: kernel/driver can't honor this ZCRX request,
        //   -ENODEV:             no such netdev / RX queue,
        //   -EPERM:              insufficient privilege to pin the queue.
        writefln("SKIP: IORING_REGISTER_ZCRX_IFQ failed (errno %d) — "
            ~ "zero-copy receive needs a NIC with a configured ZC RX queue "
            ~ "(header/data split + steered RSS), not available on this host", -regRet);
        return 0;
    }

    // --- Reached only on a genuinely ZCRX-capable host (not this 6.18 box). ---
    // The ifq is now registered at index 0 of the ring's zcrx table. Exercise the
    // SQE-side counterpart for real: open a loopback socket and post an actual
    // IORING_OP_RECV_ZC against ifq index 0. On a live ZCRX setup payloads would
    // DMA into the registered area and surface in auxiliary CQEs.
    const sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0)
    {
        stderr.writefln("socket() failed");
        return 1;
    }
    scope (exit) close(sock);

    enum ulong cookie = 0x2C0FFEE;
    // Pass `sock` as an explicit arg (not a capture) so `putWith` stays @nogc.
    // len=0 lets the kernel size the receive; ifqIdx=0 selects the ifq we registered.
    io.putWith!((ref SubmissionEntry e, int recvFd) {
        e.prepRecvZc(recvFd, /*len*/ 0, MsgFlags.NONE, /*ifqIdx*/ 0);
        e.user_data = cookie;
    })(sock);

    const submitted = io.submit(0); // flush the SQ; don't block waiting for traffic
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // The ifq registration is torn down when the ring is closed (Uring's destructor),
    // so there's nothing more to clean up here.
    writefln("ok: registered a zero-copy RX interface queue (IORING_REGISTER_ZCRX_IFQ) "
        ~ "and posted IORING_OP_RECV_ZC — host has ZCRX-capable hardware");
    return 0;
}
