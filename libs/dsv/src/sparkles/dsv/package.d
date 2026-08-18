/// `sparkles:dsv` — the Delimiter-Separated Values engine behind hue's DSV
/// preview / data browser (`docs/specs/hue/dsv-preview.md` `DSD*`/`DSM*`):
/// dialect detection (delimiter · quote · header over a bounded sample), a
/// tolerant RFC 4180 parser whose cells carry **raw byte spans** into the
/// borrowed source (the identity channel), and sampled typed columns.
///
/// The whole library is `@safe pure nothrow @nogc` (`DSM5`, the
/// `sparkles:diff` discipline): flat `SmallBuffer` arenas of plain-data
/// structs, the source borrowed and never copied (`DSN1`), errors as
/// `ParseExpected`.
///
/// Tests live in the feature modules (the runner does not discover
/// `package.d` unittests); this module only re-exports the public surface.
module sparkles.dsv;

public import sparkles.dsv.dialect : detectHeader, minConsistencyPercent,
    minDsvRecords, seedForExtension, sniff, SniffResult, sniffMaxBytes,
    sniffMaxRecords;
public import sparkles.dsv.model : CellFlags, classifyValue, ColumnType,
    decodeCell, Dialect, DsvCell, DsvDoc, DsvRecord, HeaderMode,
    inferColumnTypes, inferColumnTypesFrom, Span, Terminator, ValueKind;
public import sparkles.dsv.parse : parseDsv;
public import sparkles.dsv.project : applyProjection, compareTyped, Constraint,
    ConstraintOp, ProjectionSpec, SortKey;
