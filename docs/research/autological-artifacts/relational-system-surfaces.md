# Relational surfaces over non-relational things (osquery, Steampipe, Datasette, the CLI-SQL family)

Four systems that put a SQL front-end on something that is not a database — a running operating system, a set of cloud APIs, a bare SQLite file, a directory of CSV — and, in doing so, establish the query surface that [SELF][self] later moves _inside_ the artifact.

| Field           | Value                                                                                                                                                                              |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Family of systems: query engines that project a non-relational subject into tables                                                                                                 |
| Language        | C++ (osquery) · Go + C (Steampipe / `steampipe_postgres_fdw`) · Python (Datasette) · Go (`dsq`, `textql`) · Python (`q`)                                                           |
| License         | Apache-2.0 OR GPL-2.0-only (osquery) · AGPL-3.0 (Steampipe CLI) · Apache-2.0 (Steampipe FDW/SDK, Datasette, `dsq`) · GPL-3.0 (`q`) · MIT (`textql`)                                |
| Repository      | [osquery/osquery][osquery-repo] · [turbot/steampipe][sp-repo] · [simonw/datasette][ds-repo] · [multiprocessio/dsq][dsq-repo] · [harelba/q][q-repo] · [dinedal/textql][textql-repo] |
| Documentation   | [osquery.readthedocs.io][osquery-docs] · [steampipe.io/docs][sp-docs] · [docs.datasette.io][ds-docs]                                                                               |
| First release   | osquery `1.0.2`, 2014-10-16 · Steampipe `v0.0.15`, 2021-01-20 · Datasette `0.12`, 2017-11-16 · `dsq` `0.1.0`, 2022-01-15                                                           |
| Axis profile    | Multiplicity 1 / Reflexivity 3 / Closure 1 / Mutability 1                                                                                                                          |
| Index anchoring | Out-of-band — the "index" is the live system; the only header-anchored member is Datasette, whose subject is a real SQLite b-tree                                                  |
| Dispatch owner  | Consumer — a SQL engine (SQLite virtual-table module or Postgres FDW) decides what the subject _is_, at query-plan time                                                            |

> **Revisions surveyed:** osquery `a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b` (latest release `5.23.1`, 2026-06-24) · Steampipe `d897d7c3dba88ba6b5078f25022f41610036ba03` (`v2.4.5`, 2026-08-10) with `steampipe-postgres-fdw` `4a35fcfa9474df0ae192c3e8a29e29b98a50276e` and `steampipe-plugin-sdk` `47e1f5b297432f03a7171b75e44ca89bd6a31b7b` · Datasette `0337fba234bf574629d56be631468ea060495fa0` (stable `0.65.3`, 2026-08-06; `1.0a38` on the 1.0 line) · `dsq` `c3ae0bafb0c3283e3c98cb250ada5a19e79ad58e` (archived; upstream recommends DuckDB) · `q` `03e8b395055747a45f8c12480fd4ed95c2b4e906` · `textql` `e6545d501ca9c523110526e7b842d9301451e159`. **Platforms:** osquery Linux/macOS/Windows; Steampipe Linux/macOS/WSL2; Datasette anywhere CPython runs.

---

## Overview

### What it solves

Each of these systems answers the same complaint in a different domain: _the thing I want to ask questions about has no query language, only an API and a pile of one-off tools._ The operating system has `ps`, `lsof`, `netstat`, `find`, and `sha256sum`, each with its own output format and no join. A cloud provider has a REST API, an SDK, and a CLI whose output is JSON that you pipe into `jq`. A SQLite file has `sqlite3` and nothing else if you want to hand it to a colleague. A directory of CSVs has `awk`.

The move is uniform: **declare a schema, implement a row generator behind it, and let a real SQL engine do the planning, filtering, joining, and aggregation.** What differs — and what this page is about — is _where the rows come from at the moment the engine asks for them_, because that decision determines everything else: cost, cacheability, whether the tables can be indexed, and whether the subject can be interrogated while it is changing.

Two engines carry the whole family:

| Engine                        | Used by                     | Table mechanism                                                                                          |
| ----------------------------- | --------------------------- | -------------------------------------------------------------------------------------------------------- |
| SQLite virtual tables         | osquery, [`sqlelf`][sqlelf] | `sqlite3_module` with `xBestIndex`/`xFilter`; rows generated per scan, nothing persisted                 |
| Postgres foreign data wrapper | Steampipe                   | `CREATE FOREIGN DATA WRAPPER` + `IMPORT FOREIGN SCHEMA`; rows streamed from a gRPC plugin per scan       |
| SQLite, plain tables          | `dsq`, `q`, `textql`        | `CREATE TABLE` + bulk `INSERT`; the file is _materialized_ into a database before the query runs         |
| SQLite, unmodified            | Datasette                   | No mechanism at all — the subject already _is_ a SQLite database; Datasette adds HTTP and a policy layer |

The last row is the interesting one for this catalog, and the reason the page exists. Datasette does not project anything into tables; it takes a thing that is already tables and projects it _out_, onto HTTP. That direction reverses in [`self-httpd`][self], and the reversal is exact — see [Datasette and self-httpd: the same collapse, opposite direction](#datasette-and-self-httpd-the-same-collapse-opposite-direction).

### Design philosophy

osquery states the thesis in one sentence, in [its `README.md`][osquery-readme]:

> _"osquery exposes an operating system as a high-performance relational database. This allows you to write SQL-based queries to explore operating system data. With osquery, SQL tables represent abstract concepts such as running processes, loaded kernel modules, open network connections, browser plugins, hardware events or file hashes."_

The claim that "SQL tables represent abstract concepts" is doing real work. A `processes` row is not a record read from storage; it is a _reification_, computed by walking `/proc` at the instant the planner asked. The same sentence with "cloud API" substituted for "operating system" is Steampipe's pitch — [its `README.md`][sp-readme] opens with the SQL joke `select * from cloud;` and the phrase _"the zero-ETL way to query APIs and services."_ "Zero-ETL" is precisely the claim that no materialization step exists between the subject and the query.

The honest counterweight is stated by Steampipe's own FDW, in a comment on the row-count estimate it hands the Postgres planner ([`hub/hub_base.go`][sp-fdw-hubbase]):

```go
// steampipe-postgres-fdw/hub/hub_base.go — hubBase.GetRelSize
result := types.RelSize{
    // Default to 1M rows, because these tables are typically expensive
    // relative to standard postgres.
    Rows: 1000000,
    // Width is in bytes, assuming an average of 100 per column.
    Width: 100 * len(columns),
}
```

A foreign table is not a table. It is an API call wearing a table's clothes, and the cost model has to lie upward — pessimistically — so the planner never chooses a plan that scans it repeatedly. Every system in this family has an equivalent lie or an equivalent guard, and cataloguing them is the substance of [Closure, dedup, and size model](#closure-dedup-and-size-model).

osquery adds a second philosophical commitment that no other member shares, stated in [the pub-sub framework docs][osquery-pubsub]:

> _"From an operating systems perspective, query-time synchronous data retrieval is lossy. Consider the [processes] table: if a process like `ps` runs for a fraction of a moment there's no way `SELECT * FROM processes;` will ever include the details."_

That single observation is what turns osquery from "SQL over the OS" into the closest existing thing to _a system continuously answering questions about itself_: it forces a buffered, event-sourced half of the schema to sit next to the on-demand half. See [Event-based tables](#event-based-tables-the-buffered-half-of-the-schema).

---

## How it works

### osquery: a `sqlite3_module` per table, generated from a spec DSL

An osquery table is declared in a Python-flavoured `.table` spec, not in C++. There are **287 spec files** in the tree at the surveyed revision. [`specs/processes.table`][osquery-processes-spec] is representative:

```python
# osquery/specs/processes.table
table_name("processes")
description("All running processes on the host system.")
schema([
    Column("pid", BIGINT, "Process (or thread) ID", index=True, optimized=True),
    Column("name", TEXT, "The process path or shorthand argv[0]"),
    # ...
])
extended_schema(LINUX, [
    Column("cgroup_path", TEXT, "The full hierarchical path of the process's control group"),
])
attributes(cacheable=True, strongly_typed_rows=True)
implementation("system/processes@genProcesses")
examples(["select * from processes where pid = 1"])
```

The build turns each spec into a registered `TablePlugin`, and `attachVirtualTables` binds each one to SQLite through a `sqlite3_module` ([`osquery/sql/virtual_table.h`][osquery-vt-h], [`virtual_table.cpp`][osquery-vt-cpp]). The per-column flags — `index`, `required`, `additional`, `optimized`, `hidden`, `aliases`, `collate` — are not documentation; they are the entire contract between the table author and the query planner.

**`xBestIndex` is where an osquery table declares what it can do cheaply.** For each usable constraint SQLite offers, osquery looks up the column's options and decides whether to claim it ([`virtual_table.cpp`][osquery-vt-cpp]):

```cpp
// osquery/sql/virtual_table.cpp — xBestIndex (abridged)
const double kMaxIndexCost{1000000};
// ...
double cost = kMaxIndexCost;
// ...
const auto& options = std::get<2>(columns[constraint_info.iColumn]);
if (options & ColumnOptions::REQUIRED) {
    hasRequiredConstraints = true;
    cost = 1;
} else if (options & (ColumnOptions::INDEX | ColumnOptions::ADDITIONAL)) {
    cost = 1;
} else {
    // not indexed, let sqlite filter it
    continue;
}
```

A claimed constraint is recorded in `pVtab->content->constraints[idxNum]` and assigned an `argvIndex`, so `xFilter` can read the literal out of `argv` later. An unclaimed one is left for SQLite to apply as a post-filter over a full scan. `pIdxInfo->idxNum` is a globally incrementing `kConstraintIndexID` — the constraint set is stashed in the table's content, keyed by that id, and re-read on the matching `xFilter` call.

A comment in the same function documents the cost of getting this wrong:

> _"If we specify an index for a JOIN, it means `xFilter` is called 500 times. Therefore, when a spec file specifies a column to be required or index, the table implementation must be able to quickly find and return a single row."_

`xBestIndex` also records `pIdxInfo->colUsed` into a `UsedColumnsBitset`, resolving column aliases onto their real indices, so a generator can skip work for columns nobody selected. `sqlite3_vtab_in` is used to pull an entire `IN (…)` list through in one `xFilter` call when the column is marked `optimized`, rather than re-scanning per element.

**`xFilter` is where the row generator actually runs.** It builds a `QueryContext`, populates `context.constraints[name]` from `argv`, checks the requirement invariants, and then calls the plugin ([`virtual_table.cpp`][osquery-vt-cpp]):

```cpp
// osquery/sql/virtual_table.cpp — xFilter (abridged)
if (table->usesGenerator()) {
    pCur->uses_generator = true;
    pCur->generator = std::make_unique<RowGenerator::pull_type>(
        std::bind(&TablePlugin::generator, table, std::placeholders::_1, std::move(context)));
    if (*pCur->generator) { pCur->current = pCur->generator->get(); }
    return SQLITE_OK;
}
pCur->rows = table->generate(context);
```

Two shapes, then: a coroutine-style `generator` that yields rows lazily (the event tables use this), or an eager `generate` that materializes a `TableRows` vector into the cursor. Extension tables — tables implemented in a separate process over Thrift — take a third path, a `Registry::call("table", …, request, qd)` round trip.

**Required columns are a hard gate, not a hint.** If a table declares `required=True` on a column and no constraint on it arrives, `xFilter` logs a warning, sets a table error message, and returns `SQLITE_CONSTRAINT`. This is how osquery makes an expensive table safe to have in the schema at all: [`specs/hash.table`][osquery-hash-spec] marks both `path` and `directory` required, and [`specs/curl.table`][osquery-curl-spec] marks `url` required — so `SELECT * FROM curl` cannot become "make an HTTP request to every URL in the universe".

### Steampipe: one Postgres schema per connection, foreign tables inside

Steampipe runs an embedded PostgreSQL with a single C extension. The extension is minimal — [`fdw/steampipe_postgres_fdw--1.0.sql`][sp-fdw-sql] is the whole SQL surface:

```sql
CREATE FUNCTION fdw_handler() RETURNS fdw_handler AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FUNCTION fdw_validator(text[], oid) RETURNS void AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
CREATE FOREIGN DATA WRAPPER steampipe_postgres_fdw HANDLER fdw_handler VALIDATOR fdw_validator;
```

Everything above that line is Go, reached through cgo: `goFdwGetRelSize`, `goFdwGetPathKeys`, `goFdwBeginForeignScan`, `goFdwIterateForeignScan`, `goFdwImportForeignSchema`, `goFdwExecForeignInsert` ([`fdw.go`][sp-fdw-go]). The FDW itself talks to no cloud API; it forwards to a _plugin_ over gRPC, and the plugin — a separate process built on [`steampipe-plugin-sdk`][sp-sdk-table] — owns the schema and the fetch.

Schema creation is ordinary DDL, generated per connection ([`pkg/db/db_common/sql_connections.go`][sp-sqlconn]):

```go
// steampipe/pkg/db/db_common/sql_connections.go — GetUpdateConnectionQuery (abridged)
// Each connection has a unique schema. The schema, and all objects inside it,
// are owned by the root user.
statements.WriteString(fmt.Sprintf("drop schema if exists %s cascade;\n", connectionName))
statements.WriteString(fmt.Sprintf("create schema %s;\n", connectionName))
// Permissions are limited to select only ...
statements.WriteString(fmt.Sprintf("alter default privileges in schema %s grant select on tables to steampipe_users;\n", connectionName))
statements.WriteString(fmt.Sprintf("import foreign schema \"%s\" from server steampipe into %s;\n", pluginSchemaName, connectionName))
```

Three consequences follow directly. First, **a connection is a namespace**, so two AWS accounts are `aws_dev.aws_s3_bucket` and `aws_prod.aws_s3_bucket` and a cross-account query is an ordinary SQL join. Second, **read-only is enforced by Postgres grants**, not by the query engine — `steampipe_users` gets `SELECT` and nothing else, and writes go to `public`. Third, the schema is _discovered_, not declared in SQL: `IMPORT FOREIGN SCHEMA` calls `goFdwImportForeignSchema`, which asks the plugin for its table list.

**Key columns are the FDW's `xBestIndex`.** The SDK's `KeyColumn` ([`plugin/key_column.go`][sp-keycolumn]) names a column, the operators it accepts, and whether it is `required`, `optional`, or `any_of`. Those are translated into Postgres _path keys_ — parameterized paths the planner can choose instead of a sequential foreign scan ([`types/pathkeys.go`][sp-pathkeys]):

```go
// steampipe-postgres-fdw/types/pathkeys.go
const requiredKeyColumnBaseCost = 1
const optionalKeyColumnBaseCost = 100
const keyColumnOnlyCostMultiplier = 2
```

A path over required key columns is costed at 1–2 rows; over optional key columns, 100–200; a bare scan, the 1,000,000 from `GetRelSize`. The comment on the multiplier is candid about the intent — _"make this cheap so the planner prefers to give us the qual"_ and, when every provided qual is included, _"make this even cheaper - prefer to include all quals which were provided."_ The FDW is not estimating; it is bribing the planner into handing it the filters, because a filter it receives becomes an API parameter and a filter it does not becomes a full listing.

Notably, `getPathKeys` builds paths **only from list-call key columns**, with an explicit note that get-call key columns are deliberately excluded:

> _"NOTE: in the future we may (optionally) add in path keys for Get call key columns. We do not do this by default as it is likely to actually reduce join performance in the general case, particularly when caching is taken into account."_

### Datasette: no table mechanism, because the subject is already tables

Datasette's core loop is a thread pool executing plain `sqlite3` cursors ([`datasette/database.py`][ds-database]). The interesting code is not the query path but the _connection_ path:

```python
# datasette/database.py — Database.connect (abridged)
if self.memory_name:
    uri = f"file:{self.memory_name}?mode=memory&cache=shared"
    conn = sqlite3.connect(uri, uri=True, check_same_thread=False, **extra_kwargs)
    if not write:
        conn.execute("PRAGMA query_only=1")
    return conn
# mode=ro or immutable=1?
if self.is_mutable:
    qs = "?mode=ro"
    if self.ds.nolock:
        qs += "&nolock=1"
else:
    qs = "?immutable=1"
assert not (write and not self.is_mutable)
```

`mode=ro` versus `immutable=1` is the entire safety and performance model in two branches. `immutable=1` tells SQLite the file cannot change under it, which disables locking and change detection, and — per [`docs/performance.rst`][ds-performance] — additionally licenses Datasette to cache row counts at startup and to emit long-lived HTTP cache headers. Immutability is not a claim about the artifact; it is a promise the operator makes on the command line with `datasette -i data.db`, and Datasette spends it.

Everything the browser and the JSON API see is built on top: `/db/table.json`, `/-/query.json?sql=…`, `?_shape=`, `?_extra=`, and an opaque `?_next=` pagination token whose internal structure [the 1.0 stability promise explicitly refuses to freeze][ds-jsonapi].

### The CLI-SQL family: materialize first, ask later

`dsq`, `q`, and `textql` share an architecture that is the exact opposite of osquery's. They do not implement virtual tables. They **`CREATE TABLE` and bulk-`INSERT`** and then run the query against a genuine SQLite database.

`dsq`'s writer ([`sqlite.go`][dsq-sqlite]) shows the whole shape — the table is named after the "panel" (which is what `{}` in the query expands to), and every column gets one type:

```go
// dsq/sqlite.go — SQLiteResultItemWriter.createTable (abridged)
fieldType := "TEXT"
if sw.convertNumbers {
    fieldType = "NUMERIC"
}
create := "CREATE TABLE \"" + sw.panelId + "\"(" + strings.Join(columns, ", ") + ");"
```

`textql` makes the opposite default — every column is `NUMERIC`, leaning on SQLite's type affinity to coerce what it can ([`storage/sqlite.go`][textql-sqlite]) — and inserts through `nullif(?,'')` so empty CSV cells become `NULL`. Its database is `:memory:`; `-save-to` copies it out with SQLite's online backup API.

`q` goes furthest: with `-C readwrite` it writes a **`.qsql` file next to each input**, and that file _is_ a standard SQLite database with extra metadata tables ([`QSQL-NOTES.md`][q-qsql]):

> _"The tradeoff for using cache files is disk space - A new file with the postfix `.qsql` is created and automatically detected and used in queries as needed. This file is essentially a standard sqlite file (with some additional metadata tables), and can be used directly by any standard sqlite tool later on."_

`q` also stores a **content signature** in the cache and errors if the source file changed after the cache was built — the signature covers the parsing flags too, so querying the same CSV with a different delimiter is a cache miss rather than a wrong answer. That is a small, real instance of [embedded provenance][provenance]: the derived artifact carries enough to prove which input and which parameters produced it.

---

## Format identity and multiplicity

**This is the axis where the family scores lowest, and the low score is the finding.** None of these systems produce a byte stream that satisfies more than one parse. There is nothing here resembling [ZIP suffix parasitism][zip] or an [APE polyglot][ape]. Their multiplicity is _semantic_, not structural: one subject, many schemas over it.

Three qualified exceptions are worth recording, because each is a genuine (if minor) case of one artifact being two things at once:

1. **`q`'s `.qsql` cache is simultaneously a private cache and a public database.** It is written for `q`'s own reuse, but "can be used directly by any standard sqlite tool later on" — and `q` will also query it _in place of_ the original: `SELECT ... FROM my-csv-filename.qsql`. The same file is a build artifact and a first-class input, which is the [SQLite-as-application-file-format][sqlite-appfmt] pattern arrived at accidentally.

2. **`q` treats a plain SQLite database file as a table namespace on the command line**, with the syntax `sqlitedb_filename:::table_name`. A filename position in a shell command becomes a schema reference. Dispatch on the _name_, not the bytes — the weakest form of the [who-decides-what-a-file-is][binfmt] question in this catalog.

3. **A Datasette-published `.db` is an artifact and a website at once**, but only because a server is standing next to it. Remove the server and the multiplicity vanishes; the file is a SQLite database and always was. This is the sharpest possible contrast with the seed cases: redbean and SELF need no external process to be two things.

The osquery schema does exhibit one genuine identity split, in a different register. A table can be **local** (a `TablePlugin` in-process), **foreign** (a schema-only registration for a table that exists on another platform, amalgamated at build time so that `SELECT` against a Windows-only table on Linux fails with a _schema_ error rather than "no such table"), or an **extension** table living in another process behind Thrift. All three present identically to SQL. The `registerForeignTables()` hook that installs the cross-platform schema is guarded by `#if !defined(OSQUERY_EXTERNAL)` ([`virtual_table.h`][osquery-vt-h]) — an extension is not allowed to claim to be every platform.

Prefix- and suffix-tolerance do not apply: there are no unknown bytes to tolerate, because there are no bytes. The subject is a live system.

---

## Index anchoring and random access

The BRIEF's four anchoring choices — header, footer, stream-scanned, out-of-band — assume a file. For three of these four systems there is no file, and the honest answer is **out-of-band, degenerate case: the index does not exist**. That is not evasion; it has hard operational consequences, and they are the reason the family behaves the way it does.

| System             | What plays the role of an index                           | Cost of a "random access"                                                   |
| ------------------ | --------------------------------------------------------- | --------------------------------------------------------------------------- |
| osquery            | `ColumnOptions::INDEX`/`REQUIRED`/`OPTIMIZED` on a column | A generator that can answer a point lookup; nothing persisted between scans |
| Steampipe          | `KeyColumn` → Postgres path key → API filter parameter    | One API call with a filter, versus one API call that lists everything       |
| Datasette          | Real SQLite b-trees and real `CREATE INDEX` indexes       | Genuine `O(log n)` page reads; the only member with a real index            |
| `dsq`/`q`/`textql` | None until materialization; then SQLite's own             | The whole file is read and inserted before the first row is examined        |

**An osquery `index=True` is a promise, not a structure.** Nothing is built; the column flag only causes `xBestIndex` to cost that constraint at `1` instead of `kMaxIndexCost`, which makes SQLite hand the literal to `xFilter`, which puts it in `context.constraints`, which the C++ generator may then use to `stat` one path instead of walking a tree. If the generator ignores the constraint, the query is still correct and still slow — the "index" was a claim about the implementation that SQLite cannot verify. This is the same failure mode discussed for [`sqlelf`][sqlelf], and the same reason a virtual-table schema is not a schema in the [self-describing-format][concepts] sense.

**Datasette is the exception that clarifies the rule**, and its exceptional behaviour is _all downstream of the index being real and header-anchored_. Because SQLite's header sits at byte 0 and the b-tree is page-addressed, Datasette can:

- open the file `immutable=1` and cache per-table row counts at startup, or precompute them into a JSON file with `datasette inspect data.db --inspect-file=counts.json` and skip the count entirely ([`docs/performance.rst`][ds-performance]);
- hash the file and serve content-addressed, indefinitely-cacheable URLs;
- paginate with a **keyset** token (`?_next=`) that is a sort-key position rather than an offset, so page _N_ costs the same as page 1.

Everything in that list is a random-access affordance, and none of it is available to osquery or Steampipe, because neither has a byte offset to seek to. The generalisation — that queryability over a _remote_ artifact is a property of index anchoring, not of the query language — is developed in [range-request access][range] and is exactly the open question the catalog poses about `SELECT`ing from a [SELF binary over HTTP][self].

**Partial reads are impossible in the CLI-SQL family by construction.** `dsq` flushes rows to SQLite in batches of 100 within a 10,000-row buffer; `textql` streams CSV rows into prepared `INSERT`s inside one transaction. Either way the _entire_ input is read before the query begins, which is why `q`'s caching table reports a 5,000,000-row / 4.8 GB CSV going from 4 minutes 47 seconds to 1.92 seconds once the `.qsql` exists — a **×149 speedup that is entirely the cost of not re-materializing** ([`README.markdown`][q-readme]). The cache buys an index; the first run buys nothing.

---

## Reflexivity and query surface

This is the axis the family defines, and it earns a **3**. Two properties push it there.

### The engine describes itself in its own language

Every member exposes its own internals through the same query surface it exposes the subject through — the crucial move for this catalog, because it is what "self-describing" means operationally.

osquery ships a `utility` schema of tables about osquery: [`osquery_schedule`][osquery-sched-spec], `osquery_events`, `osquery_flags`, `osquery_registry`, `osquery_packs`, `osquery_extensions`, `osquery_info`. `osquery_schedule` is the sharpest one — it is _the cost of the daemon's own queries, as rows_:

```python
# osquery/specs/utility/osquery_schedule.table
Column("name", TEXT, "The given name for this query"),
Column("query", TEXT, "The exact query to run"),
Column("executions", BIGINT, "Number of times the query was executed"),
Column("denylisted", INTEGER, "1 if the query is denylisted else 0", aliases=["blacklisted"]),
Column("output_size", BIGINT, "Cumulative total number of bytes generated by the resultant rows of the query"),
Column("wall_time_ms", BIGINT, "Total wall time in milliseconds spent executing"),
Column("average_memory", BIGINT, "Average of the bytes of resident memory left allocated after collecting results"),
```

Steampipe's equivalent lives in the FDW's built-in `steampipe_internal` schema ([`hub/hub_base.go`][sp-fdw-hubbase]): `steampipe_scan_metadata` with `connection`, `table`, `cache_hit`, `rows_fetched`, `hydrate_calls`, `duration_ms`, `columns`, `limit`, `quals` — and a `steampipe_scan_metadata_summary` rollup. You can `SELECT` the query plan's actual behaviour, per scan, in SQL. The CLI adds `steampipe_connection`, `steampipe_plugin`, and `steampipe_rate_limiter` on top ([`design/internal_introspection_tables.md`][sp-introspection]), rebuilt on every server start.

Datasette maintains a catalog database — `INTERNAL_DB_NAME = "__INTERNAL__"` — whose tables mirror `sqlite_master` across every attached file ([`datasette/utils/internal_db.py`][ds-internaldb]):

```sql
CREATE TABLE IF NOT EXISTS catalog_databases (database_name TEXT PRIMARY KEY, path TEXT, is_memory INTEGER, schema_version INTEGER);
CREATE TABLE IF NOT EXISTS catalog_tables (database_name TEXT, table_name TEXT, rootpage INTEGER, sql TEXT, ...);
CREATE TABLE IF NOT EXISTS catalog_columns (database_name TEXT, table_name TEXT, cid INTEGER, name TEXT, type TEXT, ...);
CREATE TABLE IF NOT EXISTS catalog_indexes (...);
CREATE TABLE IF NOT EXISTS catalog_foreign_keys (...);
```

Plus an HTTP mirror of the same idea: `/-/databases`, `/-/settings`, `/-/plugins`, `/-/versions`, `/-/threads`, `/-/actions` ([`docs/introspection.rst`][ds-introspection]).

**Self-description is not decoration here; it is the debugging interface.** When a Steampipe query is slow, the answer is a `SELECT` against `steampipe_scan_metadata`. When an osquery pack is expensive, the answer is a `SELECT` against `osquery_schedule`. The query language is the only interface, so it has to cover the engine too — which is [thesis 2][concepts] arriving from an unexpected direction: a system with a general query surface is _forced_ into self-description, because there is no second channel to describe itself through.

### Event-based tables: the buffered half of the schema

osquery's second reflexive property has no analogue in the rest of the family, and it is the one that matters most for the catalog's central question.

Because synchronous generation is lossy, osquery runs a **publisher/subscriber** layer beside the virtual tables ([`osquery/events/`][osquery-events]). A publisher owns a run loop or an OS callback registration (inotify, audit, ETW, EndpointSecurity); subscribers register `Subscription`s and, on each fired event, write a row into the backing store. There are 21 `*_events` spec files in the tree — `process_events`, `file_events`, `socket_events`, `seccomp_events`, `user_events`, `ntfs_journal_events`, `es_process_events`, and so on.

Rows are stored by `addBatch` under keys of the form `data.<namespace>.<zero-padded eid>`, with the event time and an `eid` stamped into every row ([`eventsubscriberplugin.cpp`][osquery-eventsub]):

```cpp
// osquery/events/eventsubscriberplugin.cpp — addBatch (abridged)
row["time"] = string_event_time;
row["eid"]  = string_event_identifier;
serializeRowJSON(row, serialized_row);
database_data.push_back(std::make_pair("data." + dbNamespace() + "." + string_event_identifier, serialized_row));
```

The table side (`genTable`) reads the `time` constraints out of the `QueryContext` and turns them into a bounded scan of that key space, exactly the way a real index would be used:

```cpp
// osquery/events/eventsubscriberplugin.cpp — genTable (abridged)
if (context.constraints["time"].getAll().size() > 0) {
    can_optimize = false;
    for (const auto& constraint : context.constraints["time"].getAll()) {
        EventTime expr = timeFromRecord(constraint.expr);
        if (constraint.op == EQUALS)                    { stop = start = expr; break; }
        else if (constraint.op == GREATER_THAN)         { start = std::max(start, expr + 1); }
        else if (constraint.op == LESS_THAN_OR_EQUALS)  { stop  = std::min(stop, expr); }
        // ...
    }
}
```

Three flags define the buffer's economics ([`eventsubscriberplugin.cpp`][osquery-eventsub]): `--events_expiry` (default 3600 seconds), `--events_max` (default 50,000 event batches per type), and `--events_optimize` (default true). **Expiry is lazy and read-triggered** — buffered events are deleted when a query selects from the subscriber table, not on a timer, so a table nobody queries accumulates until `events_max` evicts from the front.

> [!WARNING]
> The deployment documentation and the code disagree about the expiry default.
> [`docs/wiki/development/pubsub-framework.md`][osquery-pubsub] states that
> `--events_expiry` _"is set to 1 day by default"_; the flag declaration in
> [`eventsubscriberplugin.cpp`][osquery-eventsub] reads
> `FLAG(uint64, events_expiry, 3600, ...)` — one hour. Trust the code.

`--events_optimize` is the piece that makes an event table behave like a cursor rather than a log. When the _daemon_ (not the shell) runs a scheduled query with no `time` constraint, the subscriber looks up `optimize.<query_name>` and `optimize_eid.<query_name>` in the backing store, emits only events after that point, and writes the new watermark back:

```cpp
// osquery/events/eventsubscriberplugin.cpp — generateRows (abridged)
if (can_optimize && shouldOptimize()) {
    getOptimizeData(getDatabase(), optimize_time, optimize_eid, query_name);
    start_time = optimize_time == 0 ? 0 : optimize_time - 1;
    setExecutedQuery(query_name, start_time);
}
// ... generate ...
if (can_optimize && shouldOptimize() && !result.isEnd) {
    setOptimizeData(getDatabase(), result.last_time, result.last_id);
}
```

Each scheduled query gets its **own** watermark, and expiry only runs once `executedAllQueries()` reports that every registered query has consumed the window. That is a per-consumer cursor with reference-counted retention — a message queue, implemented in a key-value store, presented as a SQL table. It is also, notably, invisible in `osqueryi`: the shell does not share RocksDB with the daemon and starts no run loops, so `SELECT * FROM process_events` in the shell is reliably empty ([`docs/wiki/development/pubsub-framework.md`][osquery-pubsub]).

### What cannot be asked

Two limits are worth stating, because they bound the "general query surface" claim.

- **Recursion is available but hostile.** SQLite's recursive CTEs work against osquery tables, but every recursion step is a fresh `xFilter` — a re-generation, not an index probe. Transitive queries (process ancestry, dependency closure) are therefore quadratic in a way an ordinary database's are not. This is precisely the SQL-versus-Datalog question the catalog raises in [open questions][open-questions] and that [code-as-database][codeasdb] systems answer differently.
- **Steampipe's only write path is a control channel.** `goFdwExecForeignInsert` returns `nil` for every real table and dispatches only when the target namespace is `steampipe_internal` ([`fdw.go`][sp-fdw-go]). The settings foreign table is two columns, `key` and `value`, and the accepted keys are `cache`, `cache_ttl`, `cache_clear_time`, `connection_cache_clear` ([`settings/keys.go`][sp-settings]). An `INSERT` is an RPC to the query engine, never a mutation of AWS.

---

## Closure, dedup, and size model

**None of these systems carry their subject**, and that is the defining structural difference from every other cluster in this catalog. Closure scores **1**, earned entirely by packaging convenience rather than by design.

| System    | What ships                                                                                      | What it does _not_ carry                                                                                                                                             |
| --------- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| osquery   | One binary with SQLite linked in; 287 table specs compiled to schema; RocksDB for its own state | The operating system. The subject is the machine and cannot be shipped                                                                                               |
| Steampipe | A CLI, an embedded Postgres, an FDW `.so`, plugins installed as OCI images                      | The cloud. Every row is a live API call or a cached copy of one                                                                                                      |
| Datasette | A Python package                                                                                | The database — supplied on the command line; `datasette publish` bundles it into a container image, which is the [packaging tree's][packaging] problem, not this one |
| `dsq`     | A single ~49 MB Go binary with SQLite and every format reader inside                            | Nothing at query time; it _does_ materialize the input, so closure is momentary                                                                                      |
| `q`       | A PyOxidizer binary with CPython 3.8 embedded (~82 MB)                                          | —                                                                                                                                                                    |
| `textql`  | ~7.3 MB Go binary                                                                               | —                                                                                                                                                                    |

The binary sizes in that table are `dsq`'s own comparison table ([`README.md`][dsq-readme]) — self-reported, from the archived project, and the only place the family quantifies its own footprint.

**The real size model in this family is the cache, not the artifact.** Each system decides independently what a stale answer is worth:

- **osquery caches whole table results in RocksDB**, keyed `cache.<table>`, valid for one scheduler `interval` ([`osquery/core/tables.cpp`][osquery-tables-cpp]). `cacheAllowed` refuses whenever any `INDEX`, `REQUIRED`, `ADDITIONAL`, or `OPTIMIZED` column carries a constraint, or when the query used non-default columns — a constrained scan is not a cacheable scan, because the cache holds one answer per table and a filtered answer is not it. `attributes(cacheable=True)` in the spec is the opt-in.
- **Steampipe caches at the row-page level**, in-plugin, with a **24-hour hard TTL ceiling** and 1000-row pages ([`query_cache/query_cache.go`][sp-querycache]). The match rule is quals-subset by default: a cached result for `val < 100` satisfies a query for `val < 50`. A table author can force `CacheMatch: "exact"` on a key column when the column is only populated _because_ a qual was supplied — an unfiltered cached row would carry `NULL` there and the subset rule would silently return wrong data. That caveat is one of the most instructive lines in the family: **a cache over a virtual table is only sound if the table's schema is a function of the query, and sometimes it is.**
- **`q` caches per input file** with a content signature covering the parsing flags; **`dsq` caches per _set_ of inputs**, keyed by a SHA-1 over all of them, into `$TMPDIR/dsq-cache-<hash>.db` ([`main.go`][dsq-main]); **`textql` does not cache at all**.
- **Datasette caches nothing** by default and pushes the problem to HTTP, which works only under the `immutable=1` promise.

There is no dedup story anywhere in this family, because there are no repeated bytes to share. That absence is itself informative when set against [Nix store closures][nix] and [content-addressed chunking][cas]: those systems dedup because the artifact is the payload. Here the artifact is a _lens_, and a lens has nothing to dedup.

---

## Mutability, dispatch, and trust

### Who dispatches

**The consumer, at plan time.** Nothing in this family is dispatched by the kernel, the shell, or the loader. A SQLite virtual-table module or a Postgres FDW handler is chosen because the query named a table, and the _table name_ is the only dispatch key. This is the weakest position on the catalog's dispatch spectrum: it requires a cooperating query engine already running in-process, which is exactly the thing [`binfmt_misc`][binfmt] removes for SELF.

Datasette dispatches twice, and the second one is genuinely a content-type decision: an HTTP route selects the database and table, and a **`.json` suffix on the URL** selects the representation — _"To access the API for a page, either click on the `.json` link on that page or edit the URL and add a `.json` extension to it"_ ([`docs/json_api.rst`][ds-jsonapi]). Suffix-based format dispatch on a _URL_ rather than on bytes; the same idea as extension sniffing, moved up a layer.

### Mutability

Mutability scores **1**, and the reasoning is uniform: **the artifact under query is never the state store.**

- osquery's differential state lives in RocksDB beside the daemon, never in the OS. `Query::addNewResults` fetches the previous result set for a scheduled query, diffs it, logs `added`/`removed`, and replaces the stored snapshot ([`osquery/core/query.cpp`][osquery-query-cpp]). The diff itself is a set-subtraction with destructive erase ([`diff_results.cpp`][osquery-diff-cpp]):

  ```cpp
  // osquery/core/sql/diff_results.cpp
  DiffResults diff(QueryDataSet& old, QueryDataTyped& current) {
      DiffResults r;
      for (auto& i : current) {
          auto item = old.find(i);
          if (item != old.end()) { old.erase(item); }
          else { r.added.push_back(i); }
      }
      for (auto& i : old) { r.removed.push_back(std::move(i)); }
      return r;
  }
  ```

  Around it sits a small amount of invalidation bookkeeping that is worth naming, because it is the part people get wrong when they reimplement this: a stored `epoch`, a monotonically increasing `counter`, and a stored copy of the **query SQL itself** under `query.<name>`. If the SQL changes, `isNewQuerySql()` fires and the previous results are treated as invalid rather than diffed against — otherwise an edited query would emit a spurious flood of `added` and `removed` rows. `getQueryCounter` even distinguishes a reset that carries all records (counter 0) from one that does not (counter 1), _"so consumers can reliably distinguish between differential results and results with all records."_ A scheduled query with `"snapshot": true` opts out of the whole mechanism and re-emits the full result set every interval ([`docs/wiki/deployment/configuration.md`][osquery-config]).

- Steampipe's writes are the settings control channel described above, plus whatever the user does in `public`. The connection schemas grant `SELECT` only.
- Datasette's default posture is `PRAGMA query_only=1` for in-memory databases and `mode=ro`/`immutable=1` for files; writes exist only through the explicit write API against a mutable database and are serialized onto a dedicated connection with `isolation_level="IMMEDIATE"`.
- `dsq`/`textql` build a throwaway database; `q`'s `.qsql` is written once and thereafter treated as immutable, guarded by its content signature.

### Trust and the cost of an expensive question

**The threat here is not code execution; it is a query.** Each system has a distinct guard, and together they form a small taxonomy that the catalog's [threat model][threat] page should inherit.

| Guard                  | System    | Mechanism                                                                                                                               |
| ---------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Refuse the question    | osquery   | `required=True` columns → `xFilter` returns `SQLITE_CONSTRAINT`; `SELECT * FROM curl` is rejected, not executed                         |
| Kill the asker         | osquery   | Watchdog process: 200 MB RSS and 10% CPU sustained for 12 s at level 0; 100 MB / 5% / 6 s at level 1 ([`watcher.cpp`][osquery-watcher]) |
| Denylist the question  | osquery   | A query the watchdog stops is denylisted and returns to the schedule after a 1-day cool-down (`denylist: false` opts out)               |
| Lie to the planner     | Steampipe | 1,000,000-row default `GetRelSize`, so no nested loop ever re-scans a foreign table                                                     |
| Bribe the planner      | Steampipe | Path-key costs of 1–2 rows for required key columns, so the qual is pushed down and becomes an API filter                               |
| Interrupt mid-query    | Datasette | `sqlite3_progress_handler` every 1000 VM instructions; return 1 past the deadline ([`datasette/utils/__init__.py`][ds-utils])           |
| Truncate the answer    | Datasette | `max_returned_rows` = 1000; `fetchmany(max + 1)` to detect truncation without materializing more                                        |
| Bound the blast radius | Datasette | `num_sql_threads` = 3; `max_csv_mb` = 100; `SQLITE_LIMIT_ATTACHED` = 10 for cross-database joins ([`datasette/app.py`][ds-app])         |

Datasette's interrupt deserves the detail, because it is the most reusable trick in the set ([`datasette/utils/__init__.py`][ds-utils]):

```python
# datasette/utils/__init__.py — sqlite_timelimit
deadline = time.perf_counter() + (ms / 1000)
# n is the number of SQLite virtual machine instructions that will be
# executed between each check. It takes about 0.08ms to execute 1000.
n = 1000

def handler():
    if time.perf_counter() >= deadline:
        # Returning 1 terminates the query with an error
        return 1

conn.set_progress_handler(handler, n)
```

The default budget is `sql_time_limit_ms = 1000`, with 200 ms for a requested facet and 50 ms for a _suggested_ one — three different opinions about how much compute an anonymous stranger on the internet may spend, all enforced by the same handler. It is what makes `default_allow_sql = True` — arbitrary SQL from the public — a defensible default at all.

The one thing nobody in this family guards is **integrity of the subject**. osquery reads `/proc` as root and believes it. Steampipe believes the API response. Datasette believes the SQLite file it was pointed at. There is no signing, no measurement, no attestation anywhere in the surveyed code — which is consistent, since none of these systems produce an artifact for anyone else to verify. The moment the query surface moves _into_ the artifact, that changes completely, and the signing problem becomes the hardest one in the catalog ([provenance][provenance], [threat model][threat]).

---

## Datasette and self-httpd: the same collapse, opposite direction

This is the comparison the catalog exists to make, and it can be made precisely, because both sides are small enough to read.

**Datasette takes a database and exposes it as HTTP.** A GET arrives, a route resolves to a database and a table, a `SELECT` runs under a 1000 ms progress-handler deadline, 1000 rows come back, and the response is JSON or HTML depending on a suffix on the URL. The database is opened `mode=ro` or `immutable=1`; the server holds no state that matters; the artifact is inert and the process is where the behaviour lives.

**`self-httpd` takes HTTP and exposes it as a database.** The program's own file is a SQLite database; `binfmt_misc` hands the interpreter the path, the program calls `sqlite3_open(argv[0])`, and serving a page is a row lookup ([`examples/server/server.c`][self-server]):

```c
/* selfdb/examples/server/server.c */
 *   argv[0]  ->  sqlite3_open()  ->  SELECT body FROM routes WHERE path = ?
```

The schema comment in [`examples/server/site/schema.sql`][self-schema] states the equivalence with the other seed case explicitly:

> _"`routes` is the content: what redbean staples on as a ZIP is, here, just rows next to `segments` and `symbols`. `visits` and `presses` are what the running site writes back into its own file."_

Line up the two systems on each of the catalog's axes and the mirror is exact:

| Question                                | Datasette                                             | `self-httpd`                                                                             |
| --------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| What is the artifact?                   | A SQLite file, inert                                  | A SQLite file that the kernel executes                                                   |
| Where does behaviour live?              | In the server process, beside the file                | In the `segments` table, inside the file                                                 |
| What is an HTTP GET?                    | A `SELECT` the server composes on the client's behalf | `SELECT body FROM routes WHERE path = ?`                                                 |
| What is a `SELECT`?                     | The primary interface, exposed at `/-/query.json`     | The deployment interface: `UPDATE routes SET body = readfile('new.html')`                |
| Who may write?                          | Nobody, by default (`mode=ro`, `query_only=1`)        | The program itself, on every request (`INSERT INTO visits`)                              |
| Does the artifact change while serving? | Deliberately not — that is what `immutable=1` buys    | Deliberately yes — the example grew 155,648 → 200,704 bytes over a few thousand requests |
| What does introspection look like?      | `/-/databases`, `catalog_tables`, `catalog_columns`   | `GET /api/tables`: `sqlite_schema` with live row counts                                  |
| What is a deploy?                       | Rebuild the file, redeploy the container              | A transaction. A rollback is `ROLLBACK`. An audit is `sqldiff --summary`                 |

The last two rows are where the reversal stops being cute and starts being a design claim. Datasette **must** put introspection in an out-of-band catalog database (`__INTERNAL__`) because it may be serving many files at once and none of them know about each other. `self-httpd` gets the same table for free — `SELECT name FROM sqlite_schema` — because there is exactly one file and it is the one running. Datasette's `/-/databases` is a reimplementation, in a second database, of what `sqlite_schema` already says about each first database. Collapse the boundary and the reimplementation disappears.

And the cost is symmetric. Datasette's whole performance story rests on the file _not_ changing (`immutable=1`, cached row counts, `datasette inspect`, HTTP caching, hashed URLs). `self-httpd`'s whole point is that the file changes, on every request. **The two systems have made opposite bets on the same variable**, and each bet buys exactly what the other one gives up. That is the cleanest available evidence for the catalog's thesis 3 — _the container is a tax_: Datasette pays a permanent tax (a second database describing the first, plus a server process that must exist for the artifact to be queryable at all) that the collapsed form simply does not owe.

What Datasette gets in return is portability, and it should not be undersold. Datasette needs no kernel cooperation, no `binfmt_misc` registration, and no privileged installation step; it runs where CPython runs. `self-httpd` runs on Linux, and only where `binfmt_misc` has been taught the SELF magic. This is [thesis 5][concepts] — portability migrating from the format to the access layer — with the two positions occupied by systems that share a b-tree and disagree about everything else.

---

## Strengths

- **One language for a heterogeneous subject.** Joining `processes` to `listening_ports` to `hash`, or `aws_dev.aws_s3_bucket` to `aws_prod.aws_s3_bucket`, is ordinary SQL. The alternative is a bespoke script per question.
- **The planner does work the table author would otherwise hand-roll.** Predicate pushdown, join ordering, aggregation, and `LIMIT` propagation come from SQLite or Postgres for free; the table author writes a row generator and a list of which constraints it can honour.
- **Self-description falls out.** Because the query surface is the only interface, the engine has to describe itself through it — `osquery_schedule`, `steampipe_scan_metadata`, `catalog_tables`. This is a genuinely reusable design lesson.
- **osquery's differential model turns polling into an event stream.** A snapshot query plus a stored previous result plus a set difference produces `added`/`removed` records with epoch and counter framing robust enough to survive a query edit — a real, deployed, decade-old answer to "how does a system continuously answer questions about itself".
- **osquery's event tables close the sampling gap** that no purely on-demand table can close, with per-consumer watermarks and reference-counted expiry underneath a plain SQL surface.
- **Datasette makes an inert file explorable with one command**, and its guards (`sql_time_limit_ms`, `max_returned_rows`, `immutable=1`) make untrusted public SQL a defensible default rather than a liability.
- **Steampipe's connection-per-schema model** turns multi-account, multi-region querying into namespacing, and enforces read-only through Postgres grants rather than through hope.

## Weaknesses

- **"Index" is a claim, not a structure.** An osquery `index=True` or a Steampipe `KeyColumn` only changes what the planner is _told_; whether the generator exploits the constraint is unverifiable from SQL. A wrong claim yields correct, catastrophically slow queries.
- **Cost models are fictions with round numbers.** 1,000,000 rows for every Steampipe foreign table; `kMaxIndexCost = 1000000` in osquery. They are chosen to steer the planner, not to describe reality, and they break down at joins where reality matters.
- **Cache soundness is subtle and table-specific.** Steampipe's subset-matching rule silently returns wrong data for "filter columns" unless the author remembers `CacheMatch: "exact"`; osquery's table cache is invalidated by the _presence_ of any constrained index column, which makes it useless for exactly the queries most worth caching.
- **Expensive tables are handled by refusal.** `SELECT * FROM curl` and `SELECT * FROM hash` cannot be answered at all. That is the right call, but it means the schema is not uniform: some tables are relations and some are function calls in a trench coat.
- **Recursive/transitive queries are second-class.** Every recursion step re-invokes `xFilter`. The queries most worth asking of a graph-shaped subject are the ones the engine handles worst — see [code as a database][codeasdb] and [open questions][open-questions].
- **Materialization is all-or-nothing in the CLI-SQL family.** `dsq`, `q`, and `textql` read the entire input before answering, so a `LIMIT 10` over a 5 GB CSV costs the same as a full aggregation. `dsq`'s own README now redirects users to DuckDB and ClickHouse-local on exactly this ground: _"These are built on stronger analytics foundations than projects like dsq based on SQLite."_
- **Type inference is a coin flip.** `dsq` defaults every column to `TEXT`; `textql` defaults every column to `NUMERIC`. Two tools, same engine, same input, different answers to `ORDER BY`.
- **No integrity story anywhere.** Nothing signs, measures, or attests. The subject is trusted absolutely.

---

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                                               | Trade-off                                                                                       |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Virtual tables (osquery) rather than an ETL into a real database          | The subject changes continuously; any materialization is stale before it lands                          | No persistent index; every scan regenerates; recursion is quadratic                             |
| Postgres FDW (Steampipe) rather than SQLite virtual tables                | Needs schemas as namespaces, real grants, `IMPORT FOREIGN SCHEMA`, and a mature planner for cross-joins | A whole embedded PostgreSQL and a cgo extension to install and version                          |
| Table schema declared in a spec DSL, compiled to C++ (osquery)            | One source for schema, cross-platform variants, docs, and the `osquery.io/schema` site                  | Adding a table means a build; extensions get a slower Thrift path instead                       |
| Column flags (`index`, `required`, `optimized`, `additional`) as contract | Gives the planner information SQLite cannot infer about a generated table                               | Unverifiable — a lying flag degrades silently                                                   |
| `required=True` → `SQLITE_CONSTRAINT` rather than a slow scan             | Makes `hash` and `curl` safe to have in a shared schema at all                                          | The schema stops being uniform; some tables cannot be browsed                                   |
| Default `GetRelSize` of 1,000,000 rows (Steampipe)                        | Prevents the planner from ever choosing a nested loop over an API                                       | Ruins genuinely small tables; every foreign scan looks equally catastrophic                     |
| Path-key costs of 1–2 for required key columns                            | Bribes the planner into pushing the qual down, where it becomes an API filter                           | Fabricated cardinalities distort join order for correct-but-different reasons                   |
| Scheduled snapshot + stored previous result + set difference (osquery)    | Emits an event stream from pollable tables; survives daemon restarts via `epoch`                        | Full result set held in RocksDB per scheduled query; a query edit invalidates the whole history |
| Read-triggered, per-query-watermark event expiry                          | Buffers exactly the window every consumer still needs, no timer, minimal disk                           | A table nobody queries grows to `events_max`; the shell can never see the daemon's buffer       |
| `immutable=1` as an operator promise (Datasette)                          | Unlocks cached row counts, `datasette inspect`, and indefinite HTTP caching                             | If the promise is false, results are silently wrong                                             |
| Progress-handler deadline every 1000 VM instructions                      | Bounds arbitrary public SQL without parsing or restricting it                                           | Granularity is ~0.08 ms of work; a single expensive instruction cannot be interrupted           |
| `max_returned_rows = 1000` with `fetchmany(max + 1)`                      | Truncation is detectable without materializing the excess                                               | The API is paginated by necessity; totals require a second query                                |
| `INSERT` into a settings foreign table as the control channel (Steampipe) | Reuses the one interface the client already speaks; no side-band protocol                               | An `INSERT` that is not an insert; only legible if you know the namespace check exists          |
| Materialize into real SQLite (`dsq`/`q`/`textql`)                         | Full SQL, real indexes, joins across files, and a reusable artifact afterwards                          | The whole input is read first; `LIMIT 1` costs a full load                                      |
| `.qsql` cache with a content signature over file + parse flags (`q`)      | ×149 on a 4.8 GB CSV, and the cache is a plain SQLite file usable by any tool                           | Disk cost per input; a changed source is an error rather than a rebuild                         |

---

## Sources

- [osquery/osquery — repository][osquery-repo] · [documentation][osquery-docs] · [table schema browser][osquery-schema]
- [`README.md` — "osquery exposes an operating system as a high-performance relational database"][osquery-readme]
- [`osquery/sql/virtual_table.cpp` — `xBestIndex`/`xFilter`, `kMaxIndexCost`, constraint routing][osquery-vt-cpp] · [`virtual_table.h`][osquery-vt-h]
- [`osquery/core/tables.cpp` — `cacheAllowed`, `isCached`, `setCache`][osquery-tables-cpp]
- [`osquery/core/query.cpp` — epoch/counter, `addNewResults`, `isNewQuerySql`][osquery-query-cpp] · [`core/sql/diff_results.cpp`][osquery-diff-cpp]
- [`osquery/events/eventsubscriberplugin.cpp` — `addBatch`, `generateRows`, optimize watermarks, expiry][osquery-eventsub]
- [`osquery/core/watcher.cpp` — watchdog limit profiles][osquery-watcher]
- [`specs/processes.table`][osquery-processes-spec] · [`specs/hash.table`][osquery-hash-spec] · [`specs/curl.table`][osquery-curl-spec] · [`specs/posix/process_events.table`][osquery-pe-spec] · [`specs/utility/osquery_schedule.table`][osquery-sched-spec]
- [`docs/wiki/development/pubsub-framework.md` — "query-time synchronous data retrieval is lossy"][osquery-pubsub] · [`docs/wiki/deployment/configuration.md` — scheduled-query keys, snapshot mode, denylisting][osquery-config]
- [turbot/steampipe — repository][sp-repo] · [steampipe.io/docs][sp-docs] · [`README.md`][sp-readme]
- [`pkg/db/db_common/sql_connections.go` — schema per connection, `IMPORT FOREIGN SCHEMA`, grants][sp-sqlconn] · [`pkg/db/db_local/internal.go`][sp-internal] · [`design/internal_introspection_tables.md`][sp-introspection]
- [`steampipe-postgres-fdw/hub/hub_base.go` — `GetRelSize`, `getPathKeys`, `steampipe_scan_metadata` schema][sp-fdw-hubbase] · [`fdw.go`][sp-fdw-go] · [`types/pathkeys.go`][sp-pathkeys] · [`fdw/steampipe_postgres_fdw--1.0.sql`][sp-fdw-sql] · [`settings/keys.go`][sp-settings]
- [`steampipe-plugin-sdk/plugin/key_column.go` — `Require`, `CacheMatch` subset vs exact][sp-keycolumn] · [`plugin/table.go`][sp-sdk-table] · [`query_cache/query_cache.go`][sp-querycache]
- [simonw/datasette — repository][ds-repo] · [docs.datasette.io][ds-docs]
- [`datasette/database.py` — `mode=ro` vs `immutable=1`, `execute`, truncation][ds-database] · [`datasette/app.py` — settings, `SQLITE_LIMIT_ATTACHED`][ds-app] · [`datasette/utils/__init__.py` — `sqlite_timelimit`][ds-utils] · [`datasette/utils/internal_db.py` — the catalog schema][ds-internaldb]
- [`docs/json_api.rst` — `.json` dispatch, 1.0 stability promise, opaque `?_next=`][ds-jsonapi] · [`docs/performance.rst` — immutable mode, `datasette inspect`, HTTP caching][ds-performance] · [`docs/introspection.rst`][ds-introspection]
- [multiprocessio/dsq — `README.md` (engine, comparison table, caching)][dsq-readme] · [`sqlite.go`][dsq-sqlite] · [`main.go`][dsq-main]
- [harelba/q — `QSQL-NOTES.md` (automatic immutable caching, content signatures)][q-qsql] · [`README.markdown` (caching speedup table)][q-readme]
- [dinedal/textql — `storage/sqlite.go` (in-memory SQLite, `NUMERIC` affinity, backup API)][textql-sqlite] · [`Readme.md`][textql-readme]
- [fzakaria/selfdb — `examples/server/README.md` (self-httpd)][self-httpd-readme] · [`examples/server/site/schema.sql`][self-schema] · [`examples/server/server.c`][self-server]
- Related in this tree: [SELF / selfdb][self] · [sqlelf][sqlelf] · [code as a database][codeasdb] · [SQLite as an application file format][sqlite-appfmt] · [the SQLite VFS as substrate][sqlite-vfs] · [range-request access][range] · [binary inspection libraries][binlib] · [`binfmt_misc`][binfmt] · [threat model][threat] · [measurement][measurement] · [comparison][comparison] · [concepts][concepts] · [open questions][open-questions]

<!-- References -->

[osquery-repo]: https://github.com/osquery/osquery
[osquery-docs]: https://osquery.readthedocs.io/en/latest/
[osquery-schema]: http://web.archive.org/web/20190131162147/https://osquery.io/schema
[osquery-readme]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/README.md
[osquery-vt-cpp]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/osquery/sql/virtual_table.cpp
[osquery-vt-h]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/osquery/sql/virtual_table.h
[osquery-tables-cpp]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/osquery/core/tables.cpp
[osquery-query-cpp]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/osquery/core/query.cpp
[osquery-diff-cpp]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/osquery/core/sql/diff_results.cpp
[osquery-eventsub]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/osquery/events/eventsubscriberplugin.cpp
[osquery-events]: https://github.com/osquery/osquery/tree/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/osquery/events
[osquery-watcher]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/osquery/core/watcher.cpp
[osquery-processes-spec]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/specs/processes.table
[osquery-hash-spec]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/specs/hash.table
[osquery-curl-spec]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/specs/curl.table
[osquery-pe-spec]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/specs/posix/process_events.table
[osquery-sched-spec]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/specs/utility/osquery_schedule.table
[osquery-pubsub]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/docs/wiki/development/pubsub-framework.md
[osquery-config]: https://github.com/osquery/osquery/blob/a1bbec2541a93ddfa373b5f1da8c16f4e4505c7b/docs/wiki/deployment/configuration.md
[sp-repo]: https://github.com/turbot/steampipe
[sp-docs]: https://steampipe.io/docs
[sp-readme]: https://github.com/turbot/steampipe/blob/d897d7c3dba88ba6b5078f25022f41610036ba03/README.md
[sp-sqlconn]: https://github.com/turbot/steampipe/blob/d897d7c3dba88ba6b5078f25022f41610036ba03/pkg/db/db_common/sql_connections.go
[sp-internal]: https://github.com/turbot/steampipe/blob/d897d7c3dba88ba6b5078f25022f41610036ba03/pkg/db/db_local/internal.go
[sp-introspection]: https://github.com/turbot/steampipe/blob/d897d7c3dba88ba6b5078f25022f41610036ba03/design/internal_introspection_tables.md
[sp-fdw-hubbase]: https://github.com/turbot/steampipe-postgres-fdw/blob/4a35fcfa9474df0ae192c3e8a29e29b98a50276e/hub/hub_base.go
[sp-fdw-go]: https://github.com/turbot/steampipe-postgres-fdw/blob/4a35fcfa9474df0ae192c3e8a29e29b98a50276e/fdw.go
[sp-pathkeys]: https://github.com/turbot/steampipe-postgres-fdw/blob/4a35fcfa9474df0ae192c3e8a29e29b98a50276e/types/pathkeys.go
[sp-fdw-sql]: https://github.com/turbot/steampipe-postgres-fdw/blob/4a35fcfa9474df0ae192c3e8a29e29b98a50276e/fdw/steampipe_postgres_fdw--1.0.sql
[sp-settings]: https://github.com/turbot/steampipe-postgres-fdw/blob/4a35fcfa9474df0ae192c3e8a29e29b98a50276e/settings/keys.go
[sp-keycolumn]: https://github.com/turbot/steampipe-plugin-sdk/blob/47e1f5b297432f03a7171b75e44ca89bd6a31b7b/plugin/key_column.go
[sp-sdk-table]: https://github.com/turbot/steampipe-plugin-sdk/blob/47e1f5b297432f03a7171b75e44ca89bd6a31b7b/plugin/table.go
[sp-querycache]: https://github.com/turbot/steampipe-plugin-sdk/blob/47e1f5b297432f03a7171b75e44ca89bd6a31b7b/query_cache/query_cache.go
[ds-repo]: https://github.com/simonw/datasette
[ds-docs]: https://docs.datasette.io/
[ds-database]: https://github.com/simonw/datasette/blob/0337fba234bf574629d56be631468ea060495fa0/datasette/database.py
[ds-app]: https://github.com/simonw/datasette/blob/0337fba234bf574629d56be631468ea060495fa0/datasette/app.py
[ds-utils]: https://github.com/simonw/datasette/blob/0337fba234bf574629d56be631468ea060495fa0/datasette/utils/__init__.py
[ds-internaldb]: https://github.com/simonw/datasette/blob/0337fba234bf574629d56be631468ea060495fa0/datasette/utils/internal_db.py
[ds-jsonapi]: https://github.com/simonw/datasette/blob/0337fba234bf574629d56be631468ea060495fa0/docs/json_api.rst
[ds-performance]: https://github.com/simonw/datasette/blob/0337fba234bf574629d56be631468ea060495fa0/docs/performance.rst
[ds-introspection]: https://github.com/simonw/datasette/blob/0337fba234bf574629d56be631468ea060495fa0/docs/introspection.rst
[dsq-repo]: https://github.com/multiprocessio/dsq
[dsq-readme]: https://github.com/multiprocessio/dsq/blob/c3ae0bafb0c3283e3c98cb250ada5a19e79ad58e/README.md
[dsq-sqlite]: https://github.com/multiprocessio/dsq/blob/c3ae0bafb0c3283e3c98cb250ada5a19e79ad58e/sqlite.go
[dsq-main]: https://github.com/multiprocessio/dsq/blob/c3ae0bafb0c3283e3c98cb250ada5a19e79ad58e/main.go
[q-repo]: https://github.com/harelba/q
[q-qsql]: https://github.com/harelba/q/blob/03e8b395055747a45f8c12480fd4ed95c2b4e906/QSQL-NOTES.md
[q-readme]: https://github.com/harelba/q/blob/03e8b395055747a45f8c12480fd4ed95c2b4e906/README.markdown
[textql-repo]: https://github.com/dinedal/textql
[textql-sqlite]: https://github.com/dinedal/textql/blob/e6545d501ca9c523110526e7b842d9301451e159/storage/sqlite.go
[textql-readme]: https://github.com/dinedal/textql/blob/e6545d501ca9c523110526e7b842d9301451e159/Readme.md
[self-httpd-readme]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/examples/server/README.md
[self-schema]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/examples/server/site/schema.sql
[self-server]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/examples/server/server.c
[self]: ./self-selfdb/index.md
[sqlelf]: ./sqlelf.md
[codeasdb]: ./code-as-database.md
[sqlite-appfmt]: ./sqlite-application-file-format.md
[sqlite-vfs]: ./sqlite-vfs-substrate.md
[range]: ./range-request-access.md
[binlib]: ./binary-inspection-libraries.md
[binfmt]: ./binfmt-misc.md
[threat]: ./threat-model.md
[provenance]: ./embedded-provenance.md
[measurement]: ./measurement.md
[comparison]: ./comparison.md
[concepts]: ./concepts.md
[open-questions]: ./open-questions.md
[zip]: ./zip-parasitism.md
[ape]: ./cosmopolitan-ape/index.md
[nix]: ./nix-store-closures.md
[cas]: ./content-addressed-chunking.md
[packaging]: ../application-packaging/index.md
