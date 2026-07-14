# TypeORM (TypeScript / JavaScript)

A decorator-based, code-first ORM for TypeScript and JavaScript whose distinguishing trait is that **one** entity model — a class annotated with `@Entity` / `@Column` / relation decorators — drives **two** persistence styles: the [Active Record][orm] pattern (`class User extends BaseEntity` → `User.findOneBy(...)`, `user.save()`) and the [Data Mapper][orm] pattern (`dataSource.getRepository(User)` → `repo.save(user)`).

| Field              | Value                                                                                                                                                        |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language           | TypeScript / JavaScript (ES2023+), Node.js + browser/Cordova/Ionic/React Native/Expo/Electron                                                                |
| License            | MIT (`LICENSE`; `package.json` `"license"`)                                                                                                                  |
| Repository         | [typeorm/typeorm][repo]                                                                                                                                      |
| Documentation      | [typeorm.io][docs] · [`docs/` in-repo][docdir]                                                                                                               |
| Category           | [Full ORM][ladder] supporting **both** [Active Record and Data Mapper][orm] patterns — decorator-based, code-first                                           |
| Abstraction level  | [Full-ORM rung][ladder]: entities with declared relations, per-save change diffing, cascades, migrations                                                     |
| Query model        | [Decorators + repository find-options][qcm] · fluent `QueryBuilder` · raw SQL / tagged template — a **runtime** value rendered to dialect SQL at execution   |
| Effect/async model | [Async][effects] (`Promise` / `async`); failures are **thrown** (`QueryFailedError` / `TypeORMError`), not a typed error channel                             |
| Backends           | PostgreSQL, MySQL/MariaDB, CockroachDB, SQLite (`better-sqlite3` / `sql.js`), MS SQL Server, Oracle, SAP HANA, Google Spanner, MongoDB (`DataSourceOptions`) |
| First release      | `0.0.1` ≈ 2016 (web-attested; `CHANGELOG.md`: _"first stable version, works with TypeScript 1.x"_)                                                           |
| Latest version     | `1.0.0` @ 2026-05-19 (the pinned tree; `CHANGELOG.md` top entry — the release that finished the `Connection` → `DataSource` rename)                          |

> [!NOTE]
> TypeORM is this survey's data point for a **decorator-driven full ORM that lets one
> entity model be used two ways**. Where `Prisma` puts the schema in a separate `.prisma`
> DSL and generates a client, and `Drizzle` / `Kysely` expose typed builders with no
> decorators, TypeORM's model _is_ ordinary TypeScript classes tagged with metadata
> decorators (`reflect-metadata` reads the emitted types). It sits at the
> [full-ORM rung][ladder] alongside `Hibernate`, `SQLAlchemy`, and Rails `ActiveRecord`
> — with change tracking, cascades, lazy relations, and a migration runner — but stacks
> the [Active Record][orm] and [Data Mapper][orm] surfaces on the same metadata. Terms
> below link to [concepts][concepts].

---

## Overview

### What it solves

TypeORM maps SQL tables to typed TypeScript classes and lets you query and mutate them
through a repository/entity-manager API (Data Mapper) or through methods on the entity
itself (Active Record). Its scope is deliberately maximal — the `README` positions it as
a run-anywhere, do-everything ORM ([`README.md`][readme]):

> _"TypeORM is an ORM that can run in Node.js, Browser, Cordova, Ionic, React Native,
> NativeScript, Expo, and Electron platforms and can be used with TypeScript and
> JavaScript (ES2023). Its goal is to always support the latest JavaScript features and
> provide additional features that help you to develop any kind of application that uses
> databases - from small applications with a few tables to large-scale enterprise
> applications with multiple databases."_

The `package.json` `description` names the lineage and the breadth of backends
([`package.json`][pkg]):

> _"Data-Mapper ORM for TypeScript and ES2023+. Supports MySQL/MariaDB, PostgreSQL, MS
> SQL Server, Oracle, SAP HANA, SQLite, MongoDB databases."_

The `README` names its influences directly — _"TypeORM is highly influenced by other
ORMs, such as Hibernate, Doctrine and Entity Framework"_ ([`README.md`][readme]) — so the
mental model is `Hibernate`/`JPA`, not a thin query builder.

### Design philosophy

The single claim TypeORM leads with — the one the rest of the library is organized around
— is that it offers **two** enterprise patterns off **one** model ([`README.md`][readme]):

> _"TypeORM supports both Active Record and Data Mapper patterns, unlike all other
> JavaScript ORMs currently in existence, which means you can write high-quality, loosely
> coupled, scalable, maintainable applications in the most productive way."_

Both are grounded in the same decorated class. The `README` shows the Data Mapper form —
a plain entity plus a repository ([`README.md`][readme]):

```typescript
import { Entity, PrimaryGeneratedColumn, Column } from 'typeorm';

@Entity()
export class User {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  firstName: string;

  @Column()
  lastName: string;

  @Column()
  age: number;
}

const userRepository = MyDataSource.getRepository(User);
await userRepository.save(user);
const allUsers = await userRepository.find();
const firstUser = await userRepository.findOneBy({ id: 1 });
```

and the Active Record form — the _same shape_, but `extends BaseEntity`, so persistence
methods live on the class ([`README.md`][readme]):

```typescript
import { Entity, PrimaryGeneratedColumn, Column, BaseEntity } from 'typeorm';

@Entity()
export class User extends BaseEntity {
  /* @PrimaryGeneratedColumn / @Column … */
}

await user.save();
const allUsers = await User.find();
const timber = await User.findOneBy({ firstName: 'Timber', lastName: 'Saw' });
```

The guide frames the choice as a maintainability-vs-simplicity trade, not a technical one
([`docs/docs/guides/1-active-record-data-mapper.md`][guide]): _"The Data Mapper approach
helps with maintainability, which is more effective in larger apps. The Active Record
approach helps keep things simple which works well in smaller apps."_ `BaseEntity` is
literally _"Base abstract entity for all entities, used in ActiveRecord patterns"_
([`src/repository/BaseEntity.ts`][baseentity]), and every static/instance method on it
just delegates to a repository — `save(options?)` calls
`baseEntity.getRepository().save(this, options)` — so **Active Record is a thin veneer
over the Data Mapper machinery**, not a parallel implementation. This is the whole design
in one fact: the two "patterns" share the persistence engine (`§ Effect model`), a
`Repository` that is _"supposed to work with your entity objects"_
([`src/repository/Repository.ts`][repository]).

The metadata approach is decorator-driven and **code-first**: decorators push into a
global `getMetadataArgsStorage()` at class-definition time, and TypeORM builds an
`EntityMetadata` graph from that. `@Entity` marks _"classes that will be an entity (table
or document depend on database type)"_ ([`src/decorator/entity/Entity.ts`][entity]) and
`@Column` marks _"a specific class property as a table column"_, with the load-bearing
caveat that _"Only properties decorated with this decorator will be persisted to the
database when entity be saved"_ ([`src/decorator/columns/Column.ts`][column]).

---

## Connection, pooling & resource lifetime

A `DataSource` is the connection configuration and the root object. Its docstring records
the rename that the pinned `1.0.0` finalized ([`src/data-source/DataSource.ts`][datasource]):

> _"DataSource is a pre-defined connection configuration to a specific database. You can
> have multiple data sources connected (with multiple connections in it), connected to
> multiple databases in your application. Before, it was called `Connection`, but now
> `Connection` is deprecated because `Connection` isn't the best name for what it's
> actually is."_

You configure it with a `DataSourceOptions` (a discriminated union over the driver
`type` — `PostgresDataSourceOptions`, `MysqlDataSourceOptions`, `SqliteDataSourceOptions`,
… — [`src/data-source/DataSourceOptions.ts`][dsoptions]) and open it with
`await dataSource.initialize()`, which builds metadata, connects the driver, optionally
runs migrations and/or `synchronize`, then sets `isInitialized = true`
([`src/data-source/DataSource.ts`][datasource]). Pooling is the driver's job, not
TypeORM's: the `README` lists _"Connection pooling"_ and _"Replication"_ among features,
and each relational driver wraps its native pool (`pg`, `mysql2`, `mssql`, …, declared as
optional `peerDependencies` in [`package.json`][pkg]). A **`QueryRunner`** is the object
that holds a single leased connection for the duration of a unit of work — every
transaction, migration, and schema-builder step runs on one; `dataSource.query(...)`
without an explicit runner leases one and releases it in a `finally`
([`src/data-source/DataSource.ts`][datasource]). Resource lifetime is therefore
callback-scoped (`transaction(cb)`) or manually managed (`queryRunner.release()`), not a
type-level [scoped][pool] acquire/release — a leaked `QueryRunner` is a runtime pool leak,
not a compile error. For large result sets, the `README` advertises _"Streaming raw
results"_ over a server-side [cursor][pool].

## Query construction & injection safety

TypeORM offers **three** query surfaces over the same entity metadata, in ascending order
of control and descending order of abstraction.

**1. Repository find-options — the declarative surface.** `repository.find(options)` /
`findOne(options)` / `findOneBy(where)` take a plain object describing the query. The
shape is typed against the entity ([`src/find-options/FindOneOptions.ts`][findoptions]):
`where` is a _"Simple condition that should be applied to match entities"_, `relations`
_"Indicates what relations of entity should be loaded (simplified left join form)"_,
plus `select`, `order`, `take`/`skip`, `lock`, and `cache`. Values in a `where` object
are never string-concatenated — they flow into the `QueryBuilder` below and become bound
parameters. The `README`'s canonical example ([`README.md`][readme]):

```typescript
const timber = await userRepository.findOneBy({
  firstName: 'Timber',
  lastName: 'Saw',
}); // find by firstName and lastName
```

`FindOptionsWhere` supports operators (`In`, `LessThan`, `Like`, `IsNull`, `Between`, …)
that wrap a value as a `FindOperator`, so even `Like("%chocolate%")` binds rather than
interpolates.

**2. The fluent `QueryBuilder` — the SQL-shaped surface.** For joins, sub-queries, and
clauses the find-options can't express, `createQueryBuilder(alias)` returns a
`SelectQueryBuilder` (siblings: `Insert`/`Update`/`Delete`/`SoftDelete`/`Relation`) whose
methods mirror SQL. It carries named `:param` placeholders. The active-record guide's
`findByName` shows the idiom verbatim ([`docs/docs/guides/1-active-record-data-mapper.md`][guide]):

```typescript
static findByName(firstName: string, lastName: string) {
    return this.createQueryBuilder("user")
        .where("user.firstName = :firstName", { firstName })
        .andWhere("user.lastName = :lastName", { lastName })
        .getMany()
}
```

`where(expr, parameters?)` _"Sets WHERE condition in the query builder … Additionally you
can add parameters used in where expression"_ ([`src/query-builder/SelectQueryBuilder.ts`][sqb]).
The `{ firstName }` object never enters the SQL text; it is stored in
`expressionMap.parameters` by `setParameter`, which **validates the key against a
character allow-list** to keep an attacker from smuggling structure through a parameter
name ([`src/query-builder/QueryBuilder.ts`][qb]):

```typescript
if (!key.match(/^([A-Za-z0-9_.]+)$/)) {
  throw new TypeORMError(
    'QueryBuilder parameter keys may only contain numbers, letters, underscores, or periods.',
  );
}
```

Values that TypeORM itself injects (a find-option `where` value, a comparison operand)
are captured by `createParameter`, which mints a fresh `orm_param_N` name, stores the
value, and emits only the placeholder `:orm_param_N` into the SQL
([`src/query-builder/QueryBuilder.ts`][qb]).

**Placeholders become bound parameters at execution.** `getQueryAndParameters()` renders
the SQL and then calls `driver.escapeQueryWithParameters(query, parameters)`
([`src/query-builder/QueryBuilder.ts`][qb]). Each driver rewrites the named `:name`
placeholders into its native positional form and pulls the values out into an ordered
array on a **separate channel** — the mechanism that makes [SQL injection][inject]
structurally impossible. Postgres, for example, replaces `:name` with `$1`, `$2`, … and
appends the values to `escapedParameters` ([`src/driver/postgres/PostgresDriver.ts`][pgdriver]):

```typescript
sql = sql.replaceAll(/:(\.\.\.)?([A-Za-z0-9_.]+)/g, (full, isArray, key) => {
  // …
  escapedParameters.push(value);
  return this.createParameter(key, escapedParameters.length - 1); // -> "$N"
});
```

The `:(\.\.\.)?` form (`:...ids`) expands an array into a placeholder list, so
`WHERE id IN (:...ids)` binds each element rather than string-joining them.

**3. Raw SQL — the escape hatch, still parameterized.** `dataSource.query(sql, params)`
_"Executes raw SQL query and returns raw database results"_ with a positional/named
`parameters` array ([`src/data-source/DataSource.ts`][datasource]). For interpolation
that stays safe, `1.0.0` adds an `sql` **tagged template** whose expressions are auto-bound
([`src/data-source/DataSource.ts`][datasource]):

> _"Tagged template function that executes raw SQL query and returns raw database results.
> Template expressions are automatically transformed into database parameters."_

```typescript
dataSource.sql`SELECT * FROM table_name WHERE id = ${id}`;
```

`buildSqlTag` walks the template: each `${expr}` becomes a driver placeholder via
`driver.createParameter(...)` and the value is pushed onto a `parameters` array, never the
SQL string ([`src/util/SqlTagUtils.ts`][sqltag]). The genuinely unsafe door is building a
SQL string yourself and passing it to `query()` with the value already concatenated in —
which no API forces you toward.

## Schema, migrations & code generation

TypeORM is **code-first**: the decorated entities _are_ the schema
([schema stances][schema]). Two paths turn them into DDL.

**Auto-synchronization (development).** `dataSource.synchronize()` (or the
`synchronize: true` option, run during `initialize`) diffs the entity metadata against the
live database and issues the `CREATE`/`ALTER` needed to converge, via the
`schema-builder`. The docs and the `README` are emphatic that this is a dev-only
convenience — it can drop columns/data — but it means _"Schema declaration in models or
separate configuration files"_ needs no migration for prototyping.

**Migrations (production).** A migration is a class implementing `MigrationInterface` with
`up(queryRunner)` / `down(queryRunner)`; `MigrationExecutor` _"Executes migrations: runs
pending and reverts previously executed migrations"_ ([`src/migration/MigrationExecutor.ts`][migexec]),
recording applied ones in a bookkeeping table and wrapping them per a `transaction` mode
([`src/migration/MigrationExecutor.ts`][migexec]):

> _"Indicates how migrations should be run in transactions. all: all migrations are run in
> a single transaction / none: all migrations are run without a transaction / each: each
> migration is run in a separate transaction"_

The headline feature is **generation from the diff**: the CLI's `migration:generate <path>`
command asks the schema-builder for the `SqlInMemory` of `upQueries` / `downQueries`
needed to bring the DB in line with the entities, and writes them into a migration file —
_"No changes in database schema were found - cannot generate a migration"_ when the diff
is empty ([`src/commands/MigrationGenerateCommand.ts`][miggen]). So the workflow is:
edit the decorated entities, `migration:generate` to author the DDL, review, commit. (You
can also `migration:create` an empty migration and write DDL by hand.) This is the same
code-first stance as `Prisma` and `EF Core`, but sourced from decorated classes rather
than a `.prisma` file or C# model. There is no first-party db-first codegen in-tree; the
community `typeorm-model-generator` fills that gap ([`README.md`][readme]).

## Type mapping & result decoding

Column types are declared on the decorator (`@Column("varchar")`,
`@Column({ type: "jsonb" })`), spanning per-database types the driver maps to native
encoders/decoders. Nullability is expressed as `@Column({ nullable: true })` and reflected
in the TypeScript field type (`name: string | null`). Row hydration is metadata-driven:
`find`/`QueryBuilder.getMany()` construct entity instances and populate only mapped
columns, with relations attached according to the load strategy below. `@Column`'s "only
decorated properties persist" rule is the decode-side contract too — an un-decorated field
is neither written nor read. Special columns get dedicated decorators
(`@PrimaryGeneratedColumn` for auto-increment/uuid keys, `@CreateDateColumn`,
`@UpdateDateColumn`, `@DeleteDateColumn` for soft-delete, `@VersionColumn` for optimistic
locking), and `@Column(() => Profile)` embeds a value object. Because the mapping leans on
`reflect-metadata`'s `design:type`, the TypeScript compiler must emit decorator metadata
(`experimentalDecorators` + `emitDecoratorMetadata`), and `reflect-metadata` must be
imported once at startup ([`docs/docs/getting-started.md`][getstarted]) — a hard
dependency on that reflection shim is a defining constraint (`§ Weaknesses`).

## Effect model, transactions & error handling

This is the dimension the survey weights most heavily, and the one where TypeORM's
mainstream-ORM heritage shows most.

**Async `Promise`, not an effect value.** Every terminal operation is `async`:
`repository.find()`, `user.save()`, `qb.getMany()`, `dataSource.query()` all return
`Promise`s awaited by the caller. There is no `IO` / `Effect` / `ConnectionIO` wrapper
([effect-typed APIs][effects] in the survey's sense) and no type-level error channel — the
"effect" is a plain JS promise, and failures are **thrown**, not returned.

**Persistence is whole-graph, diffed against loaded state.** `save(entity)` does far more
than a single `INSERT`/`UPDATE`; it drives the `persistence/` subject executor, which is
where TypeORM's [Unit of Work][orm]-style machinery lives. The pipeline: a `Subject` _"is
a subject of persistence … holds information about each entity that needs to be persisted"_
([`src/persistence/Subject.ts`][subject]); the `CascadesSubjectBuilder` _"Finds all
cascade operations of the given subject and cascade operations of the found cascaded
subjects, e.g. builds a cascade tree"_ ([`src/persistence/subject-builder/CascadesSubjectBuilder.ts`][cascades]),
so a `save` of a `User` with `cascade`-flagged relations also persists its `Profile` and
`Post`s; the `SubjectDatabaseEntityLoader` then loads each entity's current DB row
([`src/persistence/SubjectDatabaseEntityLoader.ts`][dbloader]):

> _"Loads database entities for all operate subjects which do not have database entity
> set. All entities that we load database entities for are marked as updated or inserted.
> To understand which of them really needs to be inserted or updated we need to load their
> original representations from the database."_

`SubjectChangedColumnsComputer` then _"Finds what columns are changed in the subject
entities"_ — its internal step is documented as _"Differentiate columns from the updated
entity and entity stored in the database"_ ([`src/persistence/SubjectChangedColumnsComputer.ts`][changed])
— a snapshot **diff against the freshly-loaded row**, per save call, so an `UPDATE`
touches only changed columns. Finally `SubjectExecutor` _"Executes all database operations
(inserts, updated, deletes) that must be executed with given persistence subjects"_
([`src/persistence/SubjectExecutor.ts`][subjexec]), ordering them with a
`SubjectTopologicalSorter` that _"Orders insert or remove subjects in proper order (using
topological sorting)"_ so FK dependencies are satisfied
([`src/persistence/SubjectTopologicalSorter.ts`][toposort]). This is
[change tracking][orm] realized as **load-then-diff at save time** rather than a
long-lived session snapshot: TypeORM has no per-session [identity map][orm] that would
return the same instance for two loads, and no ambient `flush` — the "unit of work" is the
graph reachable from one `save()` call. `BaseEntity.save` documents the upsert semantics
directly: _"Saves current entity in the database. If entity does not exist in the database
then inserts, otherwise updates"_ ([`src/repository/BaseEntity.ts`][baseentity]).

**Transactions: callback or manual, nested via `SAVEPOINT`.** `dataSource.transaction(cb)`
_"Wraps given function execution (and all operations made there) into a transaction. All
database operations must be executed using provided entity manager"_
([`src/data-source/DataSource.ts`][datasource]). The `EntityManager` implementation opens
a `QueryRunner`, `startTransaction`, runs the callback, commits on success and rolls back
on a thrown error ([`src/entity-manager/EntityManager.ts`][entmgr]):

```typescript
await queryRunner.startTransaction(isolation);
const result = await runInTransaction(queryRunner.manager);
await queryRunner.commitTransaction();
// catch: await queryRunner.rollbackTransaction(); throw err
```

An optional first argument sets the [isolation level][effects]. **Nesting is real** and
implemented with [savepoints][effects]: the query runner tracks a `transactionDepth`, so
an outer `transaction` emits `START TRANSACTION` while an inner one emits
`SAVEPOINT typeorm_N`, with commit/rollback mapping to `RELEASE SAVEPOINT` /
`ROLLBACK TO SAVEPOINT` ([`src/driver/postgres/PostgresQueryRunner.ts`][pgrunner]):

```typescript
if (this.transactionDepth === 0) {
  await this.query('START TRANSACTION');
  // SET TRANSACTION ISOLATION LEVEL …
} else {
  await this.query(`SAVEPOINT typeorm_${this.transactionDepth}`);
}
this.transactionDepth += 1;
```

so an inner rollback discards only the inner work while the outer transaction survives.

**Errors are thrown exceptions, not a typed channel.** A failed query throws a
`QueryFailedError` — _"Thrown when query execution has failed"_ — which carries the
`query`, the `parameters`, and the raw `driverError`
([`src/error/QueryFailedError.ts`][qferr]); a missing row from `findOneOrFail` throws
`EntityNotFoundError`; optimistic-lock conflicts throw `OptimisticLockVersionMismatchError`;
everything derives from `TypeORMError` ([`src/error/TypeORMError.ts`][tperr]). There is no
`Result`/`Either` and no `isRetryable`-style classification — to distinguish a unique-key
violation from a deadlock you inspect `error.driverError` (the underlying `pg`/`mysql2`
error and its SQLSTATE code) yourself. This is the ordinary exception posture of the
mainstream ORMs (`Hibernate`, `EF Core`), the opposite end of the axis from the
functional data mappers this survey weights (`doobie`, `Effect TS`), which keep the
failure set in the effect's type.

**Relations & the N+1 hazard.** Relations are declared with `@ManyToOne` / `@OneToMany` /
`@OneToOne` / `@ManyToMany` plus `@JoinColumn` / `@JoinTable`. `@ManyToOne` documents the
ownership rule — _"Entity1 is the owner of the relationship, and stores the id of Entity2
on its side of the relation"_ ([`src/decorator/relations/ManyToOne.ts`][manytoone]).
Loading has three modes, and the choice is where N+1 lurks:

- **Eager via join** — `find({ relations: { posts: true } })` (the _"simplified left join
  form"_ of `FindOneOptions`) or `qb.leftJoinAndSelect("post.category", "category")` pulls
  the relation in one query. `FindOneOptions` even exposes `relationLoadStrategy` to pick
  _"join"_ (one query with joins) vs _"query"_ (a separate `WHERE … IN` per relation) —
  _"If you are loading too much data with nested joins it's better to load relations using
  separate queries"_ ([`src/find-options/FindOneOptions.ts`][findoptions]).
- **Lazy `Promise`-typed relations** — if a relation property is typed `Promise<Post[]>`,
  TypeORM auto-marks it lazy (`OneToMany` inspects the reflected `design:type` and sets
  `isLazy` when the type name is `promise` — [`src/decorator/relations/OneToMany.ts`][onetomany]);
  the `RelationLoader` then _"provides lazy-load wrappers via getters/setters"_
  ([`src/query-builder/RelationLoader.ts`][relloader]), so touching `await user.posts`
  fires a query. Convenient, and the classic N+1 foot-gun: iterating N users and awaiting
  each `user.posts` is N+1 round-trips.
- **`RelationId` / relation counts** — load only the foreign keys or counts without the
  full rows.

## Ecosystem & maturity

TypeORM is one of the most-depended-upon ORMs in the Node ecosystem — the default ORM in
much of the NestJS world — released under the permissive **MIT** license
([`LICENSE`][repo]). It supports _"more databases than any other JS/TS ORM"_
([`README.md`][readme]): PostgreSQL, MySQL/MariaDB, CockroachDB, SQLite (via `sqlite3`,
`better-sqlite3`, `sql.js`, Capacitor, Cordova, Expo, React Native, NativeScript), MS SQL
Server, Oracle, SAP HANA, Google Spanner, and MongoDB (as a document store) — the
`DataSourceOptions` union enumerates all of them ([`src/data-source/DataSourceOptions.ts`][dsoptions]),
and the database packages are optional `peerDependencies` ([`package.json`][pkg]). The
feature surface is enormous: the `README`'s feature list runs to ~40 bullets — eager/lazy
relations, cascades, closure-table trees, multiple inheritance patterns, replication,
cross-database queries, query caching, listeners/subscribers (hooks), a CLI, ESM +
CommonJS. A community-extension ecosystem surrounds it (`typeorm-model-generator`,
`typeorm-extension`, fixtures loaders, ER-diagram generators — [`README.md`][readme]).
First released as `0.0.1` around 2016 (_"first stable version, works with TypeScript 1.x"_,
[`CHANGELOG.md`][changelog]); the project spent years on the `0.3.x` line and the pinned
tree is `1.0.0` (2026-05-19) — the release that dropped Node 16/18 and finished renaming
`Connection` to `DataSource` ([`CHANGELOG.md`][changelog]).

## Strengths

- **One model, two patterns.** Active Record and Data Mapper over the same decorated
  entity; the AR surface is a thin `BaseEntity` veneer over the repository engine
  ([`src/repository/BaseEntity.ts`][baseentity]).
- **Code-first with migration generation.** Edit entities, `migration:generate` diffs them
  against the DB and writes the DDL ([`src/commands/MigrationGenerateCommand.ts`][miggen]);
  `synchronize` for prototyping.
- **Injection-safe across all three surfaces.** Find-option values, `QueryBuilder` `:params`,
  and the `sql` tagged template all bind out-of-band; `escapeQueryWithParameters` splits
  SQL from data ([`src/driver/postgres/PostgresDriver.ts`][pgdriver], [`src/util/SqlTagUtils.ts`][sqltag]).
- **Whole-graph persistence.** `save` cascades, loads current rows, diffs changed columns,
  and topologically orders writes — a real unit-of-work per call
  ([`src/persistence/SubjectExecutor.ts`][subjexec]).
- **Broadest backend coverage of any JS/TS ORM**, including MongoDB, across a dozen
  runtimes ([`src/data-source/DataSourceOptions.ts`][dsoptions]).
- **Real nested transactions.** `SAVEPOINT`-based nesting with isolation levels
  ([`src/driver/postgres/PostgresQueryRunner.ts`][pgrunner]).
- **Rich `QueryBuilder` escape hatch** for anything find-options can't express, still
  parameterized ([`src/query-builder/SelectQueryBuilder.ts`][sqb]).

## Weaknesses

- **Runtime, not compile-time, query checking.** A `where` referencing a non-existent
  column, or a `QueryBuilder` string typo, is a runtime `EntityPropertyNotFoundError` /
  `QueryFailedError`, not a type error — unlike `Kysely`/`Drizzle`'s typed builders or
  `Prisma`'s generated client.
- **`reflect-metadata` + decorator config dependency.** Requires the `reflect-metadata`
  shim imported at startup and `experimentalDecorators` / `emitDecoratorMetadata` in
  `tsconfig` ([`docs/docs/getting-started.md`][getstarted]) — friction with bundlers,
  SWC/esbuild, and the newer TC39 decorators.
- **No typed error channel.** Failures are thrown `TypeORMError` subclasses; distinguishing
  a unique violation from a deadlock means reaching into `error.driverError`
  ([`src/error/QueryFailedError.ts`][qferr]) — no encoded, retryable-aware error set.
- **Lazy `Promise` relations are an N+1 trap.** Auto-lazy on `Promise`-typed properties
  ([`src/decorator/relations/OneToMany.ts`][onetomany]) makes per-parent queries easy to
  trigger accidentally.
- **Large, sometimes rough, feature surface.** ~40 headline features and many overlapping
  APIs (find-options vs `QueryBuilder` vs raw) mean more to learn and more edge cases; the
  `QueryBuilder` source still carries a long `// todo:` list ([`src/query-builder/QueryBuilder.ts`][qb]).
- **No first-party db-first codegen.** Scaffolding entities from a live schema needs a
  community tool ([`README.md`][readme]).
- **`save` semantics can surprise.** The load-diff-cascade pipeline issues extra `SELECT`s
  and can cascade further than intended if `cascade` flags are broad
  ([`src/persistence/subject-builder/CascadesSubjectBuilder.ts`][cascades]).

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                               | Trade-off                                                                                                      |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Decorator-based, code-first entities via `reflect-metadata`         | Model is plain TS classes; schema, columns, relations declared inline; no separate DSL  | Hard dependency on `reflect-metadata` + `experimentalDecorators`; no compile-time query verification           |
| Both Active Record **and** Data Mapper from one entity              | Familiar to `Hibernate`/Rails users; pick per-app-size; AR is a `BaseEntity` veneer     | Two surfaces to document/learn; AR couples domain objects to persistence                                       |
| Three query surfaces (find-options · `QueryBuilder` · raw/`sql`)    | Declarative for the common case, fluent for joins, raw for the rest — all parameterized | Overlapping APIs; when to reach for which is a judgment call; find-options can't express everything            |
| `:param` placeholders → `escapeQueryWithParameters` per driver      | Injection impossible for values; SQL and data on separate channels; multi-dialect       | You must pass values as params, never concatenate; the one unsafe door is hand-built raw SQL                   |
| `save` = load current row, diff changed columns, cascade, topo-sort | A real unit-of-work per call; `UPDATE`s touch only changed columns; graph persistence   | Extra `SELECT`s per save; no session identity map; cascades can reach further than expected                    |
| Async `Promise` + **thrown** errors                                 | Idiomatic JS; integrates with `async`/`await` everywhere                                | No effect value, no typed/retryable error channel ([effect-first][effects]); classification needs driver error |
| Lazy relations via `Promise`-typed properties                       | Ergonomic on-demand loading with plain `await`                                          | Classic [N+1][nplusone] foot-gun; loading strategy must be chosen deliberately                                 |
| Code-first migrations generated from the entity↔DB diff             | Single source of truth in the models; `migration:generate` authors DDL for you          | Generated SQL needs review; no in-tree db-first scaffolding; `synchronize` is dev-only                         |

---

## Sources

- [typeorm/typeorm — GitHub repository][repo] · [typeorm.io — official docs][docs] · [`docs/` in-repo][docdir]
- [`README.md` — positioning, "supports both Active Record and Data Mapper", influences, entity/AR/DM examples, backend list, feature list, extensions][readme]
- [`package.json` — MIT license, `"Data-Mapper ORM for TypeScript and ES2023+"`, optional database `peerDependencies`][pkg]
- [`src/decorator/entity/Entity.ts` — `@Entity` metadata decorator][entity] · [`src/decorator/columns/Column.ts` — `@Column` ("only decorated properties persist")][column] · [`src/decorator/columns/PrimaryGeneratedColumn.ts`][pgcol]
- [`src/decorator/relations/ManyToOne.ts` — relation ownership][manytoone] · [`src/decorator/relations/OneToMany.ts` — auto-lazy on `Promise` type][onetomany]
- [`src/repository/BaseEntity.ts` — Active Record base; `save` = insert-or-update; delegates to repository][baseentity] · [`src/repository/Repository.ts` — Data Mapper repository][repository]
- [`src/data-source/DataSource.ts` — `DataSource` (formerly `Connection`); `initialize`, `transaction`, `query`, `sql` tagged template, `createQueryBuilder`, `synchronize`][datasource] · [`src/data-source/DataSourceOptions.ts` — backend union][dsoptions]
- [`src/entity-manager/EntityManager.ts` — `transaction` (open runner, commit/rollback), `save` → `EntityPersistExecutor`][entmgr]
- [`src/query-builder/SelectQueryBuilder.ts` — fluent builder; `where(expr, params)`, `leftJoinAndSelect`, `getMany`][sqb] · [`src/query-builder/QueryBuilder.ts` — `setParameter` key allow-list, `createParameter` (`:orm_param_N`), `escapeQueryWithParameters`][qb]
- [`src/driver/postgres/PostgresDriver.ts` — `escapeQueryWithParameters`: `:name` → `$N`, values out-of-band, `:...arr` expansion][pgdriver] · [`src/driver/postgres/PostgresQueryRunner.ts` — `START TRANSACTION` vs `SAVEPOINT typeorm_N` by `transactionDepth`][pgrunner]
- [`src/util/SqlTagUtils.ts` — `buildSqlTag`: template expressions → bound parameters][sqltag]
- [`src/find-options/FindOneOptions.ts` — `where` / `relations` / `relationLoadStrategy` ("join" vs "query")][findoptions]
- [`src/persistence/Subject.ts` — a persistence subject][subject] · [`src/persistence/SubjectDatabaseEntityLoader.ts` — load current DB rows to diff][dbloader] · [`src/persistence/SubjectChangedColumnsComputer.ts` — diff changed columns vs DB entity][changed] · [`src/persistence/SubjectExecutor.ts` — execute inserts/updates/deletes][subjexec] · [`src/persistence/SubjectTopologicalSorter.ts` — FK-safe ordering][toposort] · [`src/persistence/subject-builder/CascadesSubjectBuilder.ts` — cascade tree][cascades]
- [`src/migration/MigrationExecutor.ts` — run/revert migrations, `transaction` "all"/"none"/"each"][migexec] · [`src/commands/MigrationGenerateCommand.ts` — `migration:generate` from the entity↔DB diff][miggen]
- [`src/query-builder/RelationLoader.ts` — lazy-load wrappers][relloader]
- [`src/error/QueryFailedError.ts` — thrown on query failure, carries `driverError`][qferr] · [`src/error/TypeORMError.ts` — base error][tperr]
- [`docs/docs/guides/1-active-record-data-mapper.md` — AR vs DM patterns, `findByName` `QueryBuilder`, "which should I choose"][guide] · [`docs/docs/getting-started.md` — `reflect-metadata` + `experimentalDecorators` setup][getstarted]
- [`CHANGELOG.md` — `0.0.1` first release, `1.0.0` @ 2026-05-19][changelog]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][qcm] · [injection][inject] · [schema/migrations][schema] · [ORM patterns][orm] · [N+1][nplusone] · [effects & transactions][effects] · [pools][pool])
- Related deep-dives in this survey: `Prisma` · `Drizzle` · `Kysely` · `Sequelize` · `EF Core` · `Hibernate` · `SQLAlchemy` · `Django ORM` · `SeaORM`

<!-- References -->

[repo]: https://github.com/typeorm/typeorm
[docs]: https://typeorm.io
[docdir]: https://github.com/typeorm/typeorm/tree/8748b1be17bf93fc9b62b3444e411e9055e9e017/docs
[readme]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/README.md
[pkg]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/package.json
[entity]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/decorator/entity/Entity.ts
[column]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/decorator/columns/Column.ts
[pgcol]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/decorator/columns/PrimaryGeneratedColumn.ts
[manytoone]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/decorator/relations/ManyToOne.ts
[onetomany]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/decorator/relations/OneToMany.ts
[baseentity]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/repository/BaseEntity.ts
[repository]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/repository/Repository.ts
[datasource]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/data-source/DataSource.ts
[dsoptions]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/data-source/DataSourceOptions.ts
[entmgr]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/entity-manager/EntityManager.ts
[sqb]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/query-builder/SelectQueryBuilder.ts
[qb]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/query-builder/QueryBuilder.ts
[pgdriver]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/driver/postgres/PostgresDriver.ts
[pgrunner]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/driver/postgres/PostgresQueryRunner.ts
[sqltag]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/util/SqlTagUtils.ts
[findoptions]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/find-options/FindOneOptions.ts
[subject]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/persistence/Subject.ts
[dbloader]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/persistence/SubjectDatabaseEntityLoader.ts
[changed]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/persistence/SubjectChangedColumnsComputer.ts
[subjexec]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/persistence/SubjectExecutor.ts
[toposort]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/persistence/SubjectTopologicalSorter.ts
[cascades]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/persistence/subject-builder/CascadesSubjectBuilder.ts
[migexec]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/migration/MigrationExecutor.ts
[miggen]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/commands/MigrationGenerateCommand.ts
[relloader]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/query-builder/RelationLoader.ts
[qferr]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/error/QueryFailedError.ts
[tperr]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/src/error/TypeORMError.ts
[guide]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/docs/docs/guides/1-active-record-data-mapper.md
[getstarted]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/docs/docs/getting-started.md
[changelog]: https://github.com/typeorm/typeorm/blob/8748b1be17bf93fc9b62b3444e411e9055e9e017/CHANGELOG.md
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[schema]: ./concepts.md#schema-migrations-code-generation
[orm]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions
