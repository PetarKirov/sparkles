#!/usr/bin/env dub
/+ dub.sdl:
    name "autological_relocation_join"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * "If relocations are a join, the loader is a query engine" — executed.
 *
 * The catalog's cluster-D claim is that `ld.so` computes, at every single
 * process start, the answer to a query it has already answered identically
 * thousands of times: for each undefined symbol, which object in the search
 * scope defines it? This program implements that query over a small in-memory
 * relational model — `objects`, `needs`, `defines`, `undefined` — and prints:
 *
 *   1. The **scope order**: a breadth-first walk of `DT_NEEDED` from the
 *      executable, deduplicated on first sight. This is the ordering rule
 *      `ld.so` uses, and it is why the *shape* of the dependency graph, not
 *      just its contents, decides which definition wins.
 *   2. The **join**, resolved under first-wins interposition, with the number
 *      of scope probes each lookup cost.
 *   3. The same computation with an `LD_PRELOAD` object spliced in at the front
 *      — SELF's "`LD_PRELOAD` becomes a row" claim, shown as exactly that: one
 *      inserted tuple, no other change, different answers.
 *   4. A **cost summary** demonstrating the confounder the measurement page
 *      warns about: the work is proportional to the *object count* traversed,
 *      not to the byte size of anything.
 *   5. The identical query written as SQL and as Datalog, so the tree's
 *      "SQL or Datalog?" open question can be read rather than argued: the
 *      transitive part is one line in Datalog and a recursive CTE in SQL.
 *
 * Nothing here is a simulation of performance — it is a statement of *what is
 * being computed*. The interesting number is the probe count, because that is
 * the quantity a materialized view (`prelink`, or a resolved-address table
 * stored in the artifact) would drive to zero.
 *
 * Companions:
 *   docs/research/autological-artifacts/dynamic-linking.md
 *   docs/research/autological-artifacts/code-as-database.md
 *   docs/research/autological-artifacts/measurement.md
 *   docs/research/autological-artifacts/self-selfdb/index.md
 *
 * Run with: `dub run --single relocation-join.d`
 *
 * Portability: pure `std`, no I/O beyond stdout. Deterministic everywhere.
 */
module autological_relocation_join;

import std.algorithm : canFind, filter, map, sum;
import std.array : array, join;
import std.conv : text;
import std.stdio : writefln, writeln;

/// One shared object in the model: the `objects` table, with its columns.
struct Object
{
    string soname;
    string[] needs; // the DT_NEEDED edges
    string[] defines; // exported definitions
    string[] undefined; // symbols this object must have resolved
}

/// One resolved relocation: the join's output row.
struct Resolution
{
    string referrer;
    string symbol;
    string provider; // null when unresolved
    size_t probes; // objects examined before the answer was found
}

/++
The scope order `ld.so` builds: breadth-first over `DT_NEEDED`, first sight wins.

Depth-first would produce a different order and therefore different
interposition winners; the breadth-first rule is the one glibc implements, and
stating it is half the point of this program — the answer to the query depends
on a traversal order that lives in the loader, not in the data.
+/
string[] scopeOrder(in Object[string] world, string root, string[] preload = null) @safe
{
    string[] order;
    bool[string] seen;

    void admit(string name)
    {
        if (name in seen)
            return;
        seen[name] = true;
        order ~= name;
    }

    admit(root);
    // `LD_PRELOAD` objects are admitted immediately after the executable and
    // before anything the executable needs — which is the whole mechanism.
    foreach (p; preload)
        admit(p);

    for (size_t i = 0; i < order.length; i++)
    {
        if (auto o = order[i] in world)
            foreach (n; o.needs)
                admit(n);
    }
    return order;
}

/++
The join itself: for every undefined symbol, the first definition in scope order.

`probes` counts how many objects were examined. In glibc this is a `.gnu.hash`
bloom-filter test per object followed by a bucket walk on a hit; the count below
is the number of objects the loader must at minimum touch, which is the quantity
that scales with object count rather than with image size.
+/
Resolution[] resolve(in Object[string] world, in string[] order) @safe
{
    Resolution[] out_;
    foreach (referrer; order)
    {
        const o = referrer in world;
        if (o is null)
            continue;
        foreach (sym; o.undefined)
        {
            size_t probes;
            string provider;
            foreach (candidate; order)
            {
                probes++;
                if (auto c = candidate in world)
                    if (c.defines.canFind(sym))
                    {
                        provider = candidate;
                        break;
                    }
            }
            out_ ~= Resolution(referrer, sym, provider, probes);
        }
    }
    return out_;
}

/// Prints one resolution table.
void printResolutions(string title, in Resolution[] rows) @safe
{
    writeln(title);
    writefln("  %-12s %-16s %-16s %s", "referrer", "symbol", "resolved to", "probes");
    writefln("  %-12s %-16s %-16s %s", "------------", "----------------", "----------------", "------");
    foreach (r; rows)
        writefln("  %-12s %-16s %-16s %s", r.referrer, r.symbol,
            r.provider.length ? r.provider : "** UNRESOLVED **", r.probes);
    writefln("  total probes: %s across %s relocations", rows.map!(r => r.probes).sum, rows.length);
    writeln;
}

int main()
{
    // A small but realistic graph: an application over a TLS library and a
    // logging library that both want `malloc`, plus a diamond on libc.
    const Object[] catalog = [
        Object("app", ["libssl.so", "liblog.so"], ["main"], ["SSL_connect", "log_write", "malloc"]),
        Object("libssl.so", ["libcrypto.so", "libc.so.6"], ["SSL_connect"], ["EVP_encrypt", "malloc"]),
        Object("liblog.so", ["libc.so.6"], ["log_write"], ["malloc", "fprintf"]),
        Object("libcrypto.so", ["libc.so.6"], ["EVP_encrypt"], ["malloc"]),
        Object("libc.so.6", [], ["malloc", "free", "fprintf"], []),
        // Present in the store but not reachable: it defines `malloc` too.
        Object("libjemalloc.so", ["libc.so.6"], ["malloc", "free"], []),
    ];

    Object[string] world;
    foreach (o; catalog)
        world[o.soname] = Object(o.soname, o.needs.dup, o.defines.dup, o.undefined.dup);

    writeln("The `objects` table (soname, |needs|, |defines|, |undefined|):");
    writeln;
    foreach (o; catalog)
        writefln("  %-16s needs=%-2s defines=%-2s undefined=%-2s   needs: %s",
            o.soname, o.needs.length, o.defines.length, o.undefined.length,
            o.needs.length ? o.needs.join(", ") : "-");
    writeln;

    const plain = scopeOrder(world, "app");
    writefln("Scope order (breadth-first over DT_NEEDED from `app`): %s", plain.join(" -> "));
    writeln("  `libjemalloc.so` is in the store but not in scope — unreachable objects");
    writeln("  do not participate in the join, which is exactly a WHERE clause.");
    writeln;

    const before = resolve(world, plain);
    printResolutions("Resolutions, no preload:", before);

    // One inserted row, at one position.
    const preloaded = scopeOrder(world, "app", ["libjemalloc.so"]);
    writefln("Scope order with LD_PRELOAD=libjemalloc.so: %s", preloaded.join(" -> "));
    writeln;
    const after = resolve(world, preloaded);
    printResolutions("Resolutions, libjemalloc.so preloaded:", after);

    // The diff is the argument: one tuple changed the answer to N queries.
    size_t changed;
    foreach (i, r; before)
        if (i < after.length && after[i].provider != r.provider)
            changed++;
    writefln("LD_PRELOAD inserted ONE row into the scope relation and changed %s of %s",
        changed, before.length);
    writefln("resolutions. Nothing about any object's bytes changed. This is why SELF");
    writeln("can model `LD_PRELOAD` as a row rather than as an environment variable.");
    writeln;

    writefln("Cost: %s probes for %s relocations over %s objects in scope.",
        before.map!(r => r.probes).sum, before.length, plain.length);
    writeln("  Every process start recomputes this. The probe count grows with the");
    writeln("  number of objects, not with how large they are — which is the confounder");
    writeln("  that makes a naive ELF-vs-SELF startup comparison meaningless unless the");
    writeln("  object count is held fixed.");
    writeln;

    writeln("The same query, two ways:");
    writeln;
    writeln("  -- SQL: the transitive part needs a recursive CTE, and the");
    writeln("  -- first-wins rule needs a window function over a traversal order");
    writeln("  -- the query itself has to reconstruct.");
    writeln("  WITH RECURSIVE scope(obj, depth) AS (");
    writeln("      SELECT 'app', 0");
    writeln("      UNION");
    writeln("      SELECT n.needed, s.depth + 1 FROM needs n JOIN scope s ON n.obj = s.obj");
    writeln("  )");
    writeln("  SELECT u.obj, u.sym, MIN(s.depth), d.obj");
    writeln("    FROM undefined u JOIN scope s JOIN defines d");
    writeln("      ON d.obj = s.obj AND d.sym = u.sym");
    writeln("   GROUP BY u.obj, u.sym;");
    writeln;
    writeln("  % Datalog: the transitive closure is one rule, and it terminates by");
    writeln("  % construction under semi-naive evaluation.");
    writeln("  scope(\"app\").");
    writeln("  scope(N) :- scope(O), needs(O, N).");
    writeln("  resolves(U, S, D) :- undefined(U, S), scope(D), defines(D, S).");
    writeln;
    writeln("  Both compute the reachable set. Only the Datalog version says nothing");
    writeln("  about *how*, which is why every code-as-a-database system that must");
    writeln("  express reachability picked it. See ../code-as-database.md.");

    return 0;
}
