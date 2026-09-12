#!/usr/bin/env dub
/+ dub.sdl:
    name "replay_journal"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Durable execution by replay — the mechanism in ~200 lines.
 *
 * A workflow is an ordinary function that performs its effects through one
 * handler, `Durable.step`. Each step has a stable key and an argument
 * fingerprint. On a live run the handler executes the step and appends the
 * result to an append-only journal. On a resumed run the same function runs
 * again from the top; while the journal still has entries the handler answers
 * each step from the journal instead of executing it, checking that the key
 * and fingerprint match what was recorded, and only once the journal is
 * exhausted does it go live again.
 *
 * The program demonstrates the two properties every system in the catalog
 * relies on (see docs/research/algebraic-effects/durable-execution/concepts.md
 * § "Replay" and § "Determinism"):
 *
 *   1. Crash-at-every-index: cutting the journal after any entry and resuming
 *      re-executes exactly the steps after the cut, and the final journal is
 *      identical to the uninterrupted run.
 *   2. Divergence detection: a step whose key or arguments differ from the
 *      recorded entry is refused, loudly, instead of silently re-run.
 *
 * It is an illustration of the replay contract, not a prototype of a library.
 *
 * Run with: `dub run --single replay-journal.d`
 */
module replay_journal;

import std.algorithm : all, equal, map;
import std.array : array;
import std.conv : text, to;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.exception : enforce;
import std.stdio : writefln, writeln;
import std.string : format;

// ── the journal ─────────────────────────────────────────────────────────────

/// One completed step. `fingerprint` is what makes replay detect a changed
/// program: the same key with different arguments is a different step.
struct Entry
{
    string key;
    string fingerprint;
    string result;
}

/// A `key` plus `args` fingerprint — the identity a step is matched on.
string fingerprintOf(string key, string args) @safe
    => sha256Of(key ~ "\0" ~ args).toHexString[0 .. 16].idup;

/// Raised when the program diverges from its journal.
class Divergence : Exception
{
    this(string msg) @safe { super(msg); }
}

// ── the handler ─────────────────────────────────────────────────────────────

/// Answers steps from the journal while it lasts, then executes them live.
struct Durable
{
    Entry[] journal;   /// the entries recorded so far (input: the prior run's)
    size_t cursor;     /// how many of them replay has consumed
    size_t executed;   /// steps that actually ran in this invocation

    /// Runs (or replays) one step. `live` is only invoked when the journal has
    /// no entry for this position.
    string step(string key, string args, scope string delegate() live)
    {
        const fp = fingerprintOf(key, args);
        if (cursor < journal.length)
        {
            const recorded = journal[cursor];
            if (recorded.key != key || recorded.fingerprint != fp)
                throw new Divergence(format!"journal entry %d is `%s` (%s) but the program asked for `%s` (%s)"(
                    cursor, recorded.key, recorded.fingerprint, key, fp));
            cursor++;
            return recorded.result;
        }
        const result = live();
        journal ~= Entry(key, fp, result);
        cursor++;
        executed++;
        return result;
    }
}

// ── the world ───────────────────────────────────────────────────────────────

/// The external state the workflow acts on. Each effect leaves a trace, so a
/// re-executed step is visible.
struct World
{
    string[] tags;
    string[] pushed;
    string[] log;   /// every effect that actually happened, in order
}

// ── the workflow ────────────────────────────────────────────────────────────

/// A miniature release: read the range, decide a version, write notes, tag,
/// push. Written once; the same function serves the first run and every
/// resume.
void releaseWorkflow(ref Durable d, ref World w, string head)
{
    const range = d.step("range", head, {
        w.log ~= "git log " ~ head;
        return "3 commits";
    });
    const version_ = d.step("decide.version", range, {
        w.log ~= "bump";
        return "v0.2.0";
    });
    const notes = d.step("notes", version_, {
        w.log ~= "agent notes for " ~ version_;
        return "notes for " ~ version_;
    });
    d.step("tag." ~ version_, notes, {
        w.log ~= "git tag " ~ version_;
        w.tags ~= version_;
        return "tagged";
    });
    d.step("push." ~ version_, "origin", {
        w.log ~= "git push " ~ version_;
        w.pushed ~= version_;
        return "pushed";
    });
}

// ── the demonstration ───────────────────────────────────────────────────────

int main()
{
    // 1. An uninterrupted run: every step executes, the journal fills.
    Durable full;
    World w0;
    releaseWorkflow(full, w0, "abc123");
    writefln("uninterrupted: %d steps executed, journal has %d entries",
        full.executed, full.journal.length);
    foreach (i, e; full.journal)
        writefln("  %d  %-16s %s  %s", i, e.key, e.fingerprint, e.result);

    // 2. Crash-at-every-index: cut after k entries, resume, compare.
    writeln();
    writeln("resume after a crash at each index:");
    writeln("  cut  replayed  executed  journal identical");
    foreach (k; 0 .. full.journal.length + 1)
    {
        Durable resumed = Durable(full.journal[0 .. k].dup);
        World w;
        releaseWorkflow(resumed, w, "abc123");
        const identical = resumed.journal.equal(full.journal);
        enforce(identical, "resume diverged from the uninterrupted run");
        enforce(resumed.executed == full.journal.length - k,
            "resume re-executed a journaled step");
        writefln("  %3d  %8d  %8d  %s", k, k, resumed.executed, identical ? "yes" : "NO");
    }

    // 3. Divergence: the same journal, but the program now asks for a different
    //    step at position 1 (a changed bump policy). Replay refuses.
    writeln();
    Durable drifted = Durable(full.journal.dup);
    string mustNotRun() { assert(false, "a journaled step must not execute"); }
    try
    {
        drifted.step("range", "abc123", &mustNotRun);
        drifted.step("decide.version", "4 commits", &mustNotRun);
        writeln("divergence NOT detected");
        return 1;
    }
    catch (Divergence e)
        writeln("divergence detected: ", e.msg);

    // 4. The world after a resume shows only the steps that were re-executed:
    //    a crash after the tag re-runs only the push.
    Durable afterTag = Durable(full.journal[0 .. 4].dup);
    World w4;
    releaseWorkflow(afterTag, w4, "abc123");
    writeln();
    writeln("effects performed when resuming after the tag: ", w4.log);
    enforce(w4.log == ["git push v0.2.0"]);
    return 0;
}
