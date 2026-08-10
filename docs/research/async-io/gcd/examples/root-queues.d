#!/usr/bin/env dub
/+ dub.sdl:
    name "gcd_root_queues"
    platforms "osx"
    targetPath "build"
+/
/**
 * GCD — the twelve global root queues, read back from a live libdispatch.
 *
 * `dispatch_get_global_queue(qos, flags)` does not create anything: it indexes
 * a static table of twelve queues that libdispatch defines at build time — six
 * QoS classes × {non-overcommit, overcommit}. This program prints the label of
 * each one, which is exactly the `dq_label` field of the corresponding entry in
 * libdispatch's `src/init.c` `_dispatch_root_queues[]` array, and asserts the
 * `com.apple.root.` prefix and the `.overcommit` suffix pairing.
 *
 * It also shows that a queue you create with `dispatch_queue_create` keeps its
 * own label, and that `dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)`
 * — a NULL argument — names whichever queue is currently running the code.
 *
 * Companion to the GCD deep-dive:
 * see docs/research/async-io/gcd/index.md § "Root queues: twelve of them, all static".
 *
 * Run with: `dub run --single root-queues.d`
 *
 * Portability: macOS only (`platforms "osx"`); libdispatch is part of
 * libSystem, so no extra link flags are needed.
 */
module gcd_root_queues;

import core.stdc.stdint : intptr_t, uintptr_t;

import std.algorithm : endsWith, startsWith;
import std.stdio : writefln, writeln;
import std.string : fromStringz;

alias dispatch_queue_t = void*;
alias dispatch_function_t = extern (C) void function(void*) nothrow;

extern (C) nothrow @nogc
{
    dispatch_queue_t dispatch_get_global_queue(intptr_t identifier, uintptr_t flags);
    dispatch_queue_t dispatch_queue_create(const(char)* label, void* attr);
    const(char)* dispatch_queue_get_label(dispatch_queue_t queue);
    void dispatch_sync_f(dispatch_queue_t queue, void* context, dispatch_function_t work);
    void dispatch_release(void* object);
}

/// `DISPATCH_QUEUE_OVERCOMMIT` — the only legal `flags` value for
/// `dispatch_get_global_queue`; selects the odd-indexed half of the table.
enum DISPATCH_QUEUE_OVERCOMMIT = 2UL;

/// The `qos_class_t` values from `<sys/qos.h>`. `dispatch_get_global_queue`
/// accepts either these or the legacy `DISPATCH_QUEUE_PRIORITY_*` integers,
/// resolving both through `_dispatch_qos_from_queue_priority`.
///
/// `MAINTENANCE` (0x05) is the odd one out: libdispatch has a root-queue pair
/// for it, but `<sys/qos.h>` declares no `QOS_CLASS_MAINTENANCE` constant — the
/// value is spelled out here to reach the twelfth and eleventh entries.
struct QosClass
{
    string name;
    intptr_t value;
}

static immutable QosClass[] qosClasses = [
    QosClass("MAINTENANCE (0x05, private)", 0x05),
    QosClass("QOS_CLASS_BACKGROUND", 0x09),
    QosClass("QOS_CLASS_UTILITY", 0x11),
    QosClass("QOS_CLASS_DEFAULT", 0x15),
    QosClass("QOS_CLASS_USER_INITIATED", 0x19),
    QosClass("QOS_CLASS_USER_INTERACTIVE", 0x21),
];

/// Runs on the created queue; `NULL` means "the queue running right now".
extern (C) void printCurrentQueue(void* context) nothrow
{
    import core.stdc.stdio : printf;

    printf("  running on:                   %s\n", dispatch_queue_get_label(null));
}

int main()
{
    writeln("QoS class                     root queue label");
    foreach (qos; qosClasses)
    {
        const plain = dispatch_get_global_queue(qos.value, 0)
            .dispatch_queue_get_label.fromStringz.idup;
        const over = dispatch_get_global_queue(qos.value, DISPATCH_QUEUE_OVERCOMMIT)
            .dispatch_queue_get_label.fromStringz.idup;

        writefln("%-29s %s", qos.name, plain);
        writefln("%-29s %s", "", over);

        // Every entry of `_dispatch_root_queues[]` is named `com.apple.root.<qos>`,
        // and the overcommit twin is the same name plus a suffix.
        assert(plain.startsWith("com.apple.root."), "unexpected root queue label: " ~ plain);
        assert(over == plain ~ ".overcommit", "overcommit twin mismatch: " ~ over);
    }

    // A queue you create is a *lane* with its own label; it owns no threads and
    // targets one of the root queues above.
    auto mine = dispatch_queue_create("dev.sparkles.research.gcd", null);
    scope (exit)
        dispatch_release(mine);

    writeln();
    writefln("created queue label:          %s", mine.dispatch_queue_get_label.fromStringz);
    dispatch_sync_f(mine, null, &printCurrentQueue);

    assert(mine.dispatch_queue_get_label.fromStringz == "dev.sparkles.research.gcd");

    // The legacy priority constants are folded onto the same table:
    // DISPATCH_QUEUE_PRIORITY_DEFAULT is 0, not a `qos_class_t` value at all.
    const legacyDefault = dispatch_get_global_queue(0, 0)
        .dispatch_queue_get_label.fromStringz.idup;
    assert(legacyDefault == "com.apple.root.default-qos",
        "DISPATCH_QUEUE_PRIORITY_DEFAULT did not resolve to the default root queue");

    writeln();
    writefln("observed %d of the 12 root queues (%d QoS classes × 2)",
        qosClasses.length * 2, qosClasses.length);
    assert(qosClasses.length == 6, "expected six QoS buckets");
    return 0;
}
