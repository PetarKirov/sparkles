#!/usr/bin/env dub
/+ dub.sdl:
    name "gcd_qos_parallelism"
    platforms "osx"
    targetPath "build"
+/
/**
 * GCD — how wide is "wide"? `pthread_qos_max_parallelism` per QoS class.
 *
 * `dispatch_apply` does not fan out to `nproc` threads. libdispatch sizes it
 * with `_dispatch_qos_max_parallelism(qos, DISPATCH_MAX_PARALLELISM_ACTIVE)`
 * (`src/shims.h`), which calls `pthread_qos_max_parallelism(qos_class, flags)`
 * and falls back to the CPU count only if that returns zero. On Apple silicon
 * the answer is *not* uniform: the background QoS class is confined to the
 * efficiency cluster, so its parallelism is the E-core count, not the total.
 *
 * This program prints the kernel's answer for each QoS class in both the
 * logical and the `PTHREAD_MAX_PARALLELISM_PHYSICAL` flavour, and asserts the
 * ordering libdispatch relies on (background never wider than default).
 *
 * Companion to the GCD deep-dive:
 * see docs/research/async-io/gcd/index.md § "`dispatch_apply` and QoS-aware parallelism".
 *
 * Run with: `dub run --single qos-parallelism.d`
 *
 * Portability: macOS only. `pthread_qos_max_parallelism` exists since macOS
 * 10.13; on an older host it returns a negative value and the program prints a
 * `SKIP:` line and exits 0.
 */
module gcd_qos_parallelism;

import std.parallelism : totalCPUs;
import std.stdio : writefln, writeln;

extern (C) nothrow @nogc int pthread_qos_max_parallelism(uint qosClass, ulong flags);

/// `PTHREAD_MAX_PARALLELISM_PHYSICAL` — count physical cores, not logical ones.
enum PTHREAD_MAX_PARALLELISM_PHYSICAL = 0x1UL;

struct QosClass
{
    string name;
    uint value;
}

static immutable QosClass[] qosClasses = [
    QosClass("QOS_CLASS_BACKGROUND", 0x09),
    QosClass("QOS_CLASS_UTILITY", 0x11),
    QosClass("QOS_CLASS_DEFAULT", 0x15),
    QosClass("QOS_CLASS_USER_INITIATED", 0x19),
    QosClass("QOS_CLASS_USER_INTERACTIVE", 0x21),
];

int main()
{
    const probe = pthread_qos_max_parallelism(qosClasses[0].value, 0);
    if (probe <= 0)
    {
        writefln("SKIP: pthread_qos_max_parallelism unavailable (returned %d)", probe);
        return 0;
    }

    writefln("std.parallelism.totalCPUs = %d", totalCPUs);
    writeln();
    writeln("QoS class                     logical  physical");

    int background, dflt;
    foreach (qos; qosClasses)
    {
        const logical = pthread_qos_max_parallelism(qos.value, 0);
        const physical = pthread_qos_max_parallelism(qos.value, PTHREAD_MAX_PARALLELISM_PHYSICAL);
        writefln("%-29s %7d  %8d", qos.name, logical, physical);

        assert(logical > 0 && physical > 0, "kernel reported non-positive parallelism");
        assert(physical <= logical, "physical parallelism exceeded logical");

        if (qos.name == "QOS_CLASS_BACKGROUND")
            background = logical;
        else if (qos.name == "QOS_CLASS_DEFAULT")
            dflt = logical;
    }

    // The invariant libdispatch's apply sizing depends on: a lower QoS class is
    // never granted more parallelism than a higher one. On an asymmetric
    // (P-core/E-core) machine this is a strict inequality.
    assert(background <= dflt, "background QoS was wider than default QoS");

    writeln();
    if (background < dflt)
        writefln("asymmetric host: background QoS is confined to %d of %d cores", background, dflt);
    else
        writefln("symmetric host: every QoS class gets %d-way parallelism", dflt);
    return 0;
}
