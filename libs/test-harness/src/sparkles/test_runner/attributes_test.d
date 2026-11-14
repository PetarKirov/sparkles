/**
 * The attributes' own end-to-end test. `sparkles:test-attributes` cannot
 * depend on the runner, so its test lives in the harness, in a module that
 * imports nothing else: it also compiles for `--wasm-bare`, whose bare wasm32
 * druntime headers reject most of `core.stdc`.
 */
module sparkles.test_runner.attributes_test;

import sparkles.test_runner.attributes : betterC, wasm;

@("attributes.selfContained.wasm")
@wasm(selfContained: true) @betterC(selfContained: true) @safe pure nothrow @nogc
unittest
{
    // Dogfoods @wasm (and @betterC) end to end, and dogfoods `selfContained`
    // itself. It lives in this import-free module on purpose, so that it also
    // compiles for `--wasm-bare`, whose bare wasm32 druntime headers reject
    // most of `core.stdc`; `--wasm` has the full druntime and Phobos.
    int parity;
    foreach (c; "wasm")
        parity ^= c;
    assert(parity == ('w' ^ 'a' ^ 's' ^ 'm'));
}
