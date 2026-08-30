/// Compile-time cost guard for schema generation: an `@ctfe` test forces a
/// fresh CTFE walk of the input vocabulary, so
/// `dub test :dql -- --ctfe-trace build/trace.json` attributes the whole
/// collection cost to this row (the `DqlSchema` table initializers are lazy
/// and memoized — mentioning `paths` alone would charge the walk to
/// whichever test touched it first).
///
/// The wsi vocabulary has no row here: the runner's probe pass derives its
/// import paths from the test build and does not see unittest-only package
/// dependencies beyond the modules' own closure, so `sparkles.wsi` fails to
/// resolve there. `libs/dql/bench/compile-time-bench.d`'s `real-wsi`
/// workload carries that measurement instead.
module sparkles.dql.schema_ctfe_test;

version (unittest):

import sparkles.test_runner.attributes : ctfe;

import sparkles.dql.schema : collectSchema;
import sparkles.input : Event;

@("dql.schema.ctfe.inputSchema")
@ctfe @safe
unittest
{
    enum table = collectSchema!Event();
    assert(table.paths.length >= 40);
    assert(table.categories.length == 8);
}
