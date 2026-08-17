/**
 * `sparkles:code-instrumentation` — code coverage data models, format
 * parsers, and overlay generation for Sparkles.
 *
 * Trace ingestion (`-ftime-trace`) is not part of this library yet: the
 * Chrome trace parser that shipped here first was a substring scanner rather
 * than a JSON parser, and it is better re-landed decoding through
 * `sparkles:wired` — which this package already depends on, and which the V8
 * coverage format uses — than kept working by inspection.
 */
module sparkles.code_instrumentation;

public import sparkles.code_instrumentation.coverage.model;
public import sparkles.code_instrumentation.coverage.ingest;
public import sparkles.code_instrumentation.coverage.overlay;
