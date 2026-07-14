# Beam (Haskell)

A type-safe, **no-Template-Haskell** relational library whose schema _is_ ordinary Haskell datatypes: a table is a record `TableT (f :: Type -> Type)` parameterized by a **column-tag functor**, so the _same_ datatype is the value type at `f ~ Identity`, the settings type at `f ~ TableField`, and the query-expression type at `f ~ QExpr` — and a monadic [`Q`][qmodels] DSL derives typed SQL from it.

| Field              | Value                                                                                                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Haskell (GHC; `DataKinds`, `TypeFamilies`, `GADTs`, generic deriving — **no** Template Haskell)                                                                     |
| License            | MIT — © 2015–2018 Travis Athougies and the Beam Authors ([`beam-core/LICENSE`][license])                                                                            |
| Repository         | [haskell-beam/beam][repo]                                                                                                                                           |
| Documentation      | [haskell-beam.github.io/beam][docs] · in-repo [`docs/`][docdir] · Hackage haddocks                                                                                  |
| Category           | [Functional data mapper][ladder] / [typed relational algebra][qmodels] over a **higher-kinded-data** schema                                                         |
| Abstraction level  | Functional data mapper — above a driver, below a full ORM ([ladder][ladder]); persistence is explicit, no change tracking                                           |
| Query model        | [Typed relational algebra][qmodels] — a value in the `Q` monad; columns are `QExpr` [phantom-typed][qmodels] expressions checked against the schema at compile time |
| Effect/async model | Blocking `IO` via `MonadBeam be m` (backend monads `Pg`, `SqliteM`); **not** an effect value, and Beam deliberately does no connection/transaction management       |
| Backends           | PostgreSQL (`beam-postgres`), SQLite (`beam-sqlite`), DuckDB (`beam-duckdb`) in-tree; MySQL/MariaDB (`beam-mysql`), Firebird (`beam-firebird`) out-of-tree          |
| First release      | ≈2016 (Hackage `beam-core` 0.2 line) — web-attested                                                                                                                 |
| Latest version     | pinned checkout: `beam-core` `0.11.2.0`, `beam-postgres` `0.6.2.0`, `beam-sqlite` `0.7.0.0`, `beam-migrate` `0.6.1.0` — web/soft                                    |

> [!NOTE]
> Beam is this survey's data point for the **higher-kinded-data** flavour of a [typed
> relational algebra][qmodels]: rather than a type-level schema (`Squeal`) or an
> arrows/profunctors query category (`Opaleye`), Beam reuses one _ordinary_ record type for
> every phase of a query's life by threading a column-tag functor through it. It sits at the
> [functional-data-mapper rung][ladder] — typed, composable queries with explicit execution
> — but, unlike the effect-first mappers this survey weights most heavily, it runs in plain
> `IO` and leaves connection/transaction management to the underlying driver. Compare with
> `Squeal` and `Opaleye` (both Haskell) on the schema-encoding axis.

---

## Overview

### What it solves

Beam turns a relational schema into a set of Haskell datatypes and lets the type checker
prove queries against them, without a code-generation step or Template Haskell. The README
states the pitch as a feature list ([`README.md`][readme]):

> _"In the design space of database libraries, Beam has the following features:_
> _\* Type-safe queries checked at compile-time;_
> _\* Predictable query performance by closely matching SQL semantics;_
> _\* Support for any relational database via pluggable backends. Backends support additional, database-specific capabilities;_
> _\* Database entities, such as tables, are modeled using standard Haskell code (in particular, Template Haskell is not needed);_
> _\* Generated SQL queries are human-readable."_

The user guide sharpens the last two points into a slogan ([`docs/index.md`][index]):
_"**No Template Haskell** Beam uses the GHC Haskell type system and nothing else."_ and
_"You can use Beam's `Q` monad much like you would interact with the `[]` monad."_ The whole
library is built to be _inferrable_: schemas are plain records, instances are empty, and the
compiler figures out the rest.

### Design philosophy

Three commitments define Beam, each a verbatim claim from its own documentation.

**Type-safety through the type system, not codegen.** ([`README.md`][readme]):

> _"Beam uses the Haskell type system to verify that queries are type-safe at compile time.
> Queries are written in a straightforward, natural monadic syntax."_

**Higher-kinded data instead of a fully-polymorphic row.** Beam's signature idea is that a
table need take only _one_ type parameter, not one per column. The FAQ draws the contrast
against `Opaleye` directly ([`docs/about/faq.md`][faq]):

> _"Beam uses higher-kinded types to allow the use of 'normal' haskell data types, rather
> than a fully polymorphic type."_

and insists the encoding needs no metaprogramming ([`docs/about/faq.md`][faq]):

> _"Moreover, all beam instances and type synonyms are easily written by hand. There is no
> Template Haskell magic here. What you see is what you get."_

**Do less, on purpose.** Beam is unopinionated about the runtime: it generates and decodes
SQL and stops there ([`README.md`][readme]):

> _"Recognizing that over-abstraction frequently means caving in to the lowest common
> denominator, Beam does not do connection or transaction management. Rather, the user is
> free to perform these functions using the appropriate Haskell interface library for their
> backend of choice."_

That last decision is the one that most distances Beam from the effect-first mappers in this
survey (`doobie`, `skunk`, the `Effect TS` `sql` layer): there is no `Resource`/`Scope`
acquire-release, no pool combinator, and no `withTransaction` in `beam-core` — those are the
driver's job.

---

## Connection, pooling & resource lifetime

There is almost nothing here, and that is the finding. Beam owns no connection type and no
pool; a backend package binds an existing Haskell driver and Beam borrows its connection.
`beam-postgres` is layered on `postgresql-simple` ([`beam-postgres/…/Postgres.hs`][pgmod]):

> _"The @beam-postgres@ module is built atop of @postgresql-simple@, which is used for
> connection management, transaction support, serialization, and deserialization."_

Concretely, you hand a _driver_ connection to a `runBeam*` entry point
([`beam-postgres/…/Connection.hs`][pgconn]):

```haskell
-- beam-postgres: Database/Beam/Postgres/Connection.hs
runBeamPostgres      :: Pg.Connection -> Pg a -> IO a
runBeamPostgresDebug :: (String -> IO ()) -> Pg.Connection -> Pg a -> IO a
```

`beam-sqlite` mirrors this with `runBeamSqlite :: Connection -> SqliteM a -> IO a` over a
`sqlite-simple` `Connection`. Because Beam never opens or closes a connection, **pooling,
resource scoping, and transaction boundaries are entirely the driver's concern** — you reach
for `resource-pool`, `postgresql-simple`'s `withTransaction`, and `bracket`. For an
[effects-first][effects] survey this is the sharp contrast: where `Slick` hands out a
database as a `Resource`/`Scope` and `doobie` keeps a `Transactor`, Beam's `Pg`/`SqliteM`
actions are just `IO` interpreters (see [Effect model](#effect-model-transactions-error-handling))
with a connection captured by closure — a leaked or mis-scoped connection is _not_ a Beam-level
type error.

---

## Query construction & injection safety

This is Beam's centre of gravity, and it rests on two mechanisms: **higher-kinded data** for
the schema, and the monadic **`Q`** DSL for the query.

### Higher-kinded data: `Columnar`, `C`, and one type for every phase

A Beam table is a record parameterized by a _column tag_ `f`. Each field wraps its Haskell
type in the `Columnar` type family, whose reduction rules decide what that tag _means_
([`beam-core/…/Schema/Tables.hs`][tables]):

```haskell
-- beam-core: Database/Beam/Schema/Tables.hs
type family Columnar (f :: Type -> Type) x where
    Columnar Exposed x        = Exposed x
    Columnar Identity x       = x
    Columnar (Lenses t f) x   = LensFor (t f) (Columnar f x)
    Columnar (Nullable c) x   = Columnar c (Maybe x)
    Columnar f x              = f x

-- | A short type-alias for 'Columnar'. May shorten your schema definitions
type C f a = Columnar f a
```

The payoff, stated in the `Columnar` haddock, is that _one_ datatype serves every role
([`beam-core/…/Schema/Tables.hs`][tables]):

> _"This is what allows us to use the same table type to hold table data, describe table
> settings, derive lenses, and provide expressions."_

The pivotal rule is `Columnar Identity x = x`: applying a table to `Identity` collapses every
field to its bare Haskell type, giving the plain "value" record
([`beam-core/…/Schema/Tables.hs`][tables]: _"any Beam table applied to `Identity` will yield
a simplified version of the data type, that contains just what you'd expect."_). The other
tags reinterpret the _same_ fields — `TableField` for settings/naming, `Nullable f` for
`NULL`able foreign keys (`Columnar (Nullable f) a ~ Maybe (Columnar f a)`), and `QExpr` for
query expressions. A schema is thus:

```haskell
data UserT f = User
  { _userEmail     :: Columnar f Text
  , _userFirstName :: Columnar f Text
  , _userLastName  :: Columnar f Text
  , _userPassword  :: Columnar f Text
  } deriving (Generic, Beamable)

type User = UserT Identity            -- the value type: every field is its bare Haskell type

instance Table UserT where
  data PrimaryKey UserT f = UserId (Columnar f Text) deriving (Generic, Beamable)
  primaryKey = UserId . _userEmail
```

The `Table` class is the only user-written machinery: it carries an associated **data family**
`PrimaryKey` and the `primaryKey` extractor, while `Beamable` (an empty, generically-derived
instance) provides the introspection Beam needs. The class haddock explains the kind
([`beam-core/…/Schema/Tables.hs`][tables]):

> _"The kind of all table types is `(Type -> Type) -> Type`. This is because all table types
> are actually /table type constructors/. Every table type takes in another type constructor,
> called the /column tag/, and uses that constructor to instantiate the column types."_

Tables are grouped into a **`Database`**, itself a higher-kinded record whose fields are
`f (TableEntity T)` entity slots ([`beam-core/…/Schema/Tables.hs`][tables]):

```haskell
data ShoppingCartDb f = ShoppingCartDb
  { _shoppingCartUsers :: f (TableEntity UserT)
  } deriving (Generic, Database be)

shoppingCartDb :: DatabaseSettings be ShoppingCartDb
shoppingCartDb = defaultDbSettings   -- Generic-derives snake_case names, no boilerplate
```

`defaultDbSettings` derives the table/column names from the record selectors via
`GHC.Generics`, so the schema declaration doubles as its own naming metadata.

### The `Q` monad DSL

A query is a value in `Q be db s a` — a **free monad** (`newtype Q … = Q { runQ :: F (QF be db s) a }`,
[`beam-core/…/Query/Internal.hs`][qinternal]) whose commands (`QAll`, `QGuard`,
`QArbitraryJoin`, `QAggregate`, …) are reified and later compiled to SQL. Its doc pins the
type parameters ([`beam-core/…/Query/Internal.hs`][qinternal]):

> _"The type of queries over the database `db` returning results of type `a`. The `s`
> argument is a threading argument meant to restrict cross-usage of `QExpr`s."_

The `s` phantom parameter is the same rank-2 "region" trick `ST` uses: it prevents a `QExpr`
born in one scope from leaking into an incompatible one (which is how Beam forbids illegal
`LATERAL`-style dependencies). `all_` introduces a table as a row of expressions
([`beam-core/…/Query/Combinators.hs`][combinators]):

```haskell
-- beam-core: Database/Beam/Query/Combinators.hs
all_ :: BeamSqlBackend be
     => DatabaseEntity be db (TableEntity table)
     -> Q be db s (table (QExpr be s))          -- every column is now a QExpr

guard_  :: BeamSqlBackend be => QExpr be s Bool -> Q be db s ()
filter_ mkExpr clause = clause >>= \x -> guard_ (mkExpr x) >> pure x

-- relationships compile down to an inner join on the primary key
related_    relTbl relKey = join_ relTbl (\rel -> relKey ==. primaryKey rel)
references_ fk tbl        = fk ==. pk tbl
```

Because `Q` is a `Monad`, joins are just `>>=`: bind two `all_`s and constrain them with
`guard_`. Aggregation is `aggregate_ :: (r -> a) -> Q be db (QNested s) r -> Q be db s …`,
which rewrites the inner query's context into a grouped one. A complete query reads like a
list-monad comprehension and runs through one `select`:

```haskell
runBeamSqliteDebug putStrLn conn $ do
  users <- runSelectReturningList $
             select $
             orderBy_ (\u -> asc_ (_userFirstName u)) $
             filter_  (\u -> _userLastName u ==. val_ "Smith") $
             all_ (_shoppingCartUsers shoppingCartDb)
  mapM_ (liftIO . print) users
```

### Why it is injection-safe

An expression never becomes a `String`. A `QExpr` is a _function that builds backend syntax_
([`beam-core/…/Query/Internal.hs`][qinternal]):

```haskell
-- beam-core: Database/Beam/Query/Internal.hs
newtype QGenExpr context be s t = QExpr (TablePrefix -> BeamSqlBackendExpressionSyntax be)
type QExpr = QGenExpr QValueContext
```

so `_userLastName u ==. val_ "Smith"` does not compute a `Bool` — it _constructs an AST node_.
User values enter **only** through `val_`, which lifts a Haskell literal to a bound parameter
via `valueE . sqlValueSyntax` ([`beam-core/…/Query/Combinators.hs`][combinators]:
`val_ = QExpr . pure . valueE . sqlValueSyntax`). There is no interpolation surface: the
query is an AST, and literals travel out-of-band as bind parameters. The tutorial makes the
guarantee explicit, showing the emitted `?` placeholders ([`docs/tutorials/tutorial1.md`][tut1]):

> _"The `?` represent the values passed to the database (beam uses the backend's value
> interpolation to avoid SQL injection attacks)."_

The **escape hatch** is `Database.Beam.Query.CustomSQL`: `customExpr_` turns a string-like
builder (`Monoid`/`IsString`) into a `QGenExpr`, which is where a user _can_ splice raw text
and reintroduce risk ([`beam-core/…/Query/CustomSQL.hs`][customsql]). It is opt-in and rare;
the default surface has no place to put a string.

### The backend Syntax tower

`select` freezes a `Q` into a first-class command whose SQL is not yet rendered
([`beam-core/…/Query.hs`][query]):

```haskell
-- beam-core: Database/Beam/Query.hs
newtype SqlSelect be a = SqlSelect (BeamSqlBackendSelectSyntax be)

select :: (BeamSqlBackend be, HasQBuilder be, Projectible be res)
       => Q be db QBaseScope res -> SqlSelect be (QExprToIdentity res)
select q = SqlSelect (buildSqlQuery "t" q)
```

The `BeamSqlBackend` class links a backend _tag_ type (`Postgres`, `Sqlite`) to a concrete
syntax type through an open type family, and requires that syntax to satisfy the standards
tower ([`beam-core/…/Backend/SQL.hs`][backendsql]):

```haskell
-- beam-core: Database/Beam/Backend/SQL.hs
class ( BeamBackend be
      , IsSql92Syntax (BeamSqlBackendSyntax be)      -- SQL92 semantics, at least
      , Sql92SanityCheck (BeamSqlBackendSyntax be)
      , HasSqlValueSyntax (BeamSqlBackendValueSyntax be) Bool
      , … ) => BeamSqlBackend be
type family BeamSqlBackendSyntax be :: Type
```

`IsSql92Syntax` is the base of a stack of finely-split classes (`IsSql92SelectSyntax`,
`IsSql92SelectTableSyntax`, `IsSql92ExpressionSyntax`, … up through `SQL99` and `SQL2003`
modules), each an associated-type-carrying interface a backend implements. A combinator that
uses a non-SQL92 feature demands the matching capability _as a class constraint_, so a query
is polymorphic over exactly the backends that support it ([`docs/about/faq.md`][faq]:
_"Beam is also fully polymorphic over the backend … Feature constraints are written as class
constraints."_). One `Q` value, many dialects, checked at compile time — and the generated SQL
is human-readable by design.

---

## Schema, migrations & code generation

Beam is **code-first**: the entity datatypes above _are_ the schema. `beam-core` on its own
already lets that schema emit and read data, but schema _evolution_ lives in a separate
package, `beam-migrate` ([`beam-migrate/beam-migrate.cabal`][migratecabal]: _"SQL DDL support
and migrations support library for Beam … write type-safe schema generation code."_).

`beam-migrate`'s central abstraction is the **checked database** — a `DatabaseSettings`
augmented with a set of _predicates_ (facts the schema asserts about a live database)
([`beam-migrate/…/Migrate.hs`][migrate]):

> _"A checked database (represented by the `CheckedDatabaseSettings` type) consists of a set
> of database entities along with a set of /predicates/ … The /predicates/ are facts about a
> given database schema. For example, a checked database with a table named "Customers", would
> have a `TableExistsPredicate` in its predicate set."_

From predicate sets, `beam-migrate` both **checks** and **migrates**
([`beam-migrate/…/Migrate/Simple.hs`][migratesimple]):

```haskell
-- beam-migrate: Database/Beam/Migrate/Simple.hs
data VerificationResult = VerificationSucceeded | VerificationFailed [SomeDatabasePredicate]

verifySchema :: (Database be db, MonadBeam be m)
             => BeamMigrationBackend be m -> CheckedDatabaseSettings be db -> m VerificationResult
autoMigrate  :: (Database be db, Fail.MonadFail m) => …   -- runs the solved DDL, refusing on data loss
bringUpToDate, createSchema, checkSchema :: …
```

A `heuristicSolver` computes the minimal DDL to bring a database satisfying one predicate set
to another; `autoMigrate` runs it (and _refuses_ when the diff implies data loss). Going the
other direction, `beam-migrate` can render a predicate set as **Haskell** via
`Database.Beam.Haskell.Syntax`, so tooling can generate a Beam schema _from an existing
database_ — the [db-first][schemamig] codegen path. Predicates also serialize to JSON, giving
a diffable schema snapshot. Crucially, all of this is achieved with generic deriving and type
classes — **no Template Haskell**, the standing contrast with `persistent`'s quasi-quoter.

---

## Type mapping & result decoding

Decoding a result row is governed by `FromBackendRow` ([`beam-core/…/Backend/SQL/Row.hs`][row]):

```haskell
-- beam-core: Database/Beam/Backend/SQL/Row.hs
class BeamBackend be => FromBackendRow be a where
  fromBackendRow :: FromBackendRowM be a
  default fromBackendRow :: (Typeable a, BackendFromField be a) => FromBackendRowM be a
  fromBackendRow = parseOneField
  valuesNeeded :: Proxy be -> Proxy a -> Int
```

`FromBackendRowM` is itself a small free-monad parser over the result cells (with an
`Alternative` for `peekField`), and the per-backend `BackendFromField be` constraint plugs in
the driver's own field decoders (`postgresql-simple`'s `FromField`, `sqlite-simple`'s). Row
hydration for a whole table is **generic**: `GFromBackendRow` matches the table's generic
`Rep` against its `Exposed` shape, so `UserT Identity` decodes column-by-column with no
hand-written instance. Encoding is the dual `HasSqlValueSyntax` used by `val_`.

**Nullability is in the type**, two ways. A scalar optional column is a `Maybe`
(`Columnar f (Maybe Text)`); an optional _foreign key_ uses the `Nullable` tag, and the
`Columnar (Nullable c) x = Columnar c (Maybe x)` rule pushes `Maybe` through every column of
the embedded key ([`docs/user-guide/models.md`][models]:
_"`Columnar (Nullable f) a ~ Maybe (Columnar f a)` for all `a`."_). Left joins return
`table (Nullable (QExpr be s))`, so an absent join row is a type-level `Maybe`, not a runtime
surprise.

---

## Effect model, transactions & error handling

This is where Beam sits furthest from the survey's effect-first flagships. Execution is
mediated by **`MonadBeam`**, a low-level class tying a monad to a backend
([`beam-core/…/Backend/SQL.hs`][backendsql]):

```haskell
-- beam-core: Database/Beam/Backend/SQL.hs
class (BeamBackend be, Monad m) => MonadBeam be m | m -> be where
  {-# MINIMAL runReturningMany #-}
  runReturningMany :: FromBackendRow be x
                   => BeamSqlBackendSyntax be
                   -> (m (Maybe x) -> m a) -> m a       -- pull the next row, or Nothing
  runNoReturn      :: BeamSqlBackendSyntax be -> m ()
  runReturningOne  :: FromBackendRow be x => BeamSqlBackendSyntax be -> m (Maybe x)
  runReturningList :: FromBackendRow be x => BeamSqlBackendSyntax be -> m [x]
```

Its own doc frames it as plumbing ([`beam-core/…/Backend/SQL.hs`][backendsql]:
_"a low-level interface for executing commands. The `run*` functions are wrapped by the
appropriate functions in `Database.Beam.Query`."_). The user-facing runners —
`runSelectReturningList`, `runSelectReturningOne`, `runInsert`, `runUpdate`, `runDelete` —
wrap a `SqlSelect`/`SqlInsert`/… and dispatch to these methods.

The concrete backend monads are **plain `IO` interpreters**, not effect values:

```haskell
-- beam-postgres: a free monad over IO
newtype Pg a = Pg { runPg :: F PgF a }
    deriving (Monad, Applicative, Functor, MonadFree PgF, MonadIO)
instance MonadBeam Postgres Pg where
    runReturningMany cmd consume = liftF (PgRunReturning CursorBatching cmd consume id)

-- beam-sqlite: a ReaderT over IO
newtype SqliteM a = SqliteM { runSqliteM :: ReaderT (String -> IO (), Connection) IO a }
```

So a `Pg`/`SqliteM` value is a _description that is interpreted straight to `IO`_ by
`runBeamPostgres`/`runBeamSqlite`; there is no `ZIO`/`Effect`/`ConnectionIO` carrying a typed
error or a required environment. This is the axis the [effects survey][effects] cares about:
Beam is **blocking `IO`**, comparable to a JDBC-shaped library, whereas `doobie`/`skunk`
return a `ConnectionIO` and `Quill`'s ZIO contexts narrow the error channel to a type.

**Errors are exceptions, untyped.** `runBeamPostgresDebug` runs the action and rethrows into
`IO` (`… >>= either throwIO pure`); a decoding failure surfaces as a thrown `BeamRowReadError`
and driver failures as `postgresql-simple`/`sqlite-simple` exceptions. There is no
enumerated `SqlError`-style channel in the type.

**Transactions and pooling are out of scope by design** — the README's "Beam does not do
connection or transaction management" is a hard boundary. `beam-core` ships no
`withTransaction`, no savepoint API, and no isolation-level combinator; you wrap a `runBeam*`
call in `postgresql-simple`'s `withTransaction` (or `sqlite-simple`'s) yourself. What Beam
_does_ offer at runtime is **streaming**: `runReturningMany` exposes a pull-based cursor (the
Postgres instance batches with `CursorBatching`), and `beam-postgres` adds a `conduit` API for
constant-memory result processing.

---

## Ecosystem & maturity

Beam is a mature, MIT-licensed project ([`beam-core/LICENSE`][license]) authored by Travis
Athougies and maintained under the [`haskell-beam`][repo] org, distributed on Hackage and
Stackage. The monorepo pins `beam-core` `0.11.2.0` with the in-tree backends `beam-postgres`
`0.6.2.0`, `beam-sqlite` `0.7.0.0`, `beam-duckdb` `0.3.1.0`, and the `beam-migrate` `0.6.1.0`
DDL/migrations library. Additional backends — `beam-mysql`, `beam-firebird` — are packaged
independently, exactly as the modular design intends: _"Backends can be written and maintained
independently of this repository"_ ([`README.md`][readme]). Documentation is generated with
`mkdocs`, and — notably — its query examples are **checked against a live Chinook database at
build time**, so a broken example fails the docs build ([`README.md`][readme]). The library
predates 2016 on Hackage (web-attested); the pinned tree is a stable, actively-maintained
line.

---

## Strengths

- **One datatype for every phase.** The higher-kinded-data encoding (`Columnar f a`) means a
  single `TableT f` record is the value type (`Identity`), the naming/settings type
  (`TableField`), and the query-expression type (`QExpr`) — far less boilerplate than a
  per-column type parameter, and _no_ Template Haskell.
- **Compile-time-checked queries in a familiar monad.** The `Q` monad reads like the list
  monad; a mistyped comparison, a wrong-table column, or a nullability mismatch is a type
  error, and the `s` region parameter blocks illegal cross-scope expression use.
- **Structural injection safety.** Expressions are ASTs, never strings; user values enter only
  as `val_` bind parameters. The lone escape hatch (`customExpr_`) is opt-in.
- **One query, many dialects.** The `IsSql92Syntax` tower plus capability-as-constraint makes
  a query polymorphic over precisely the backends that support its features; generated SQL is
  human-readable.
- **Code-first schema _and_ db-first reflection.** `beam-migrate` derives migrations and a
  solver from the Haskell schema, verifies a live database against it, _and_ can generate a
  Beam schema from an existing database.
- **Unopinionated runtime.** Bring your own driver, pool, and transaction strategy — Beam
  layers cleanly over `postgresql-simple`/`sqlite-simple` and never fights them.

## Weaknesses

- **Blocking `IO`, no effect value.** `Pg`/`SqliteM` interpret straight to `IO`; there is no
  `ConnectionIO`/`ZIO`/`Effect` carrying typed errors or a required environment — the very
  property this survey weights most.
- **Untyped errors.** Failures are thrown exceptions (`BeamRowReadError`, driver exceptions),
  not an enumerated error channel.
- **No transaction or pool management.** No `withTransaction`, savepoint, or isolation API in
  `beam-core`; correctness of transaction boundaries and resource scoping is the user's
  responsibility, unenforced by the type system.
- **Type-error ergonomics.** The type-family/generic machinery (`Columnar`, `Beamable`,
  `Projectible`, the syntax tower) produces long, higher-kinded error messages when a
  constraint is unmet — the standard cost of this style of Haskell library.
- **`Nullable` nests `Maybe`.** `Columnar (Nullable f) (Maybe a) ~ Maybe (Maybe a)`, which the
  manual itself flags as a "misfeature" collapsed to a single SQL `NULL` on the wire
  ([`docs/user-guide/models.md`][models]).

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                                          | Trade-off                                                                                                   |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| **Higher-kinded data** — a table is `TableT f`, columns are `Columnar f a` | One ordinary record serves as value, settings, and query-expression type; no per-column type param | Type errors are large and higher-kinded; `Columnar` is a type family, so `f` can be ambiguous (`Columnar'`) |
| **No Template Haskell** — pure type-classes + `GHC.Generics`               | Instances are hand-writable and inspectable; "what you see is what you get"                        | Leans on advanced type-level features (`DataKinds`, type families, generic deriving) instead                |
| **`Q` as a free monad with an `s` region parameter**                       | Familiar monadic/`for`-style queries; rank-2 `s` forbids illegal cross-scope `QExpr` use           | The `s`/`QNested s` threading complicates advanced combinator signatures                                    |
| **Expressions are AST builders (`QExpr`), values via `val_`**              | Injection is structurally impossible; the query is data a backend renders                          | Raw SQL requires the `customExpr_` escape hatch, which can reintroduce risk                                 |
| **Backend = tag type + `IsSql92Syntax` tower; features as constraints**    | One query targets many dialects; unsupported features are compile errors, not runtime ones         | A deep tower of split classes/associated types; writing a new backend is substantial                        |
| **Code-first schema, migrations in a separate `beam-migrate`**             | Core stays lean (generate + decode SQL); migration is opt-in with a solver and db-first reflection | Two packages to learn; migration solving is heuristic and refuses ambiguous/lossy diffs                     |
| **Blocking `IO` via `MonadBeam`; no connection/txn management**            | Small, unopinionated surface; composes with any Haskell driver                                     | No effect value, no typed errors, no transaction/pool/resource safety from Beam itself                      |

---

## Sources

- [haskell-beam/beam — GitHub repository][repo] · [haskell-beam.github.io/beam — user guide][docs] · [in-repo `docs/`][docdir]
- [`README.md` — feature list, "no Template Haskell", "does not do connection or transaction management", human-readable SQL][readme]
- [`docs/about/faq.md` — higher-kinded types vs `Opaleye`, "no Template Haskell magic", backend polymorphism][faq]
- [`docs/index.md` — "No Template Haskell", `Q` monad "like the `[]` monad"][index]
- [`beam-core/…/Schema/Tables.hs` — `Columnar`/`C` type family, `Table`/`Beamable`/`Database`, `PrimaryKey` data family][tables]
- [`beam-core/…/Query/Internal.hs` — `Q` free monad, `QF` commands, `QGenExpr`/`QExpr`, the `s` region parameter][qinternal]
- [`beam-core/…/Query/Combinators.hs` — `all_`, `guard_`, `filter_`, `related_`/`references_`, `val_`][combinators]
- [`beam-core/…/Query.hs` — `SqlSelect`, `select`, `runSelectReturning*`, `SqlInsert`/`runInsert`][query]
- [`beam-core/…/Backend/SQL.hs` — `MonadBeam`, `runReturningMany`, `BeamSqlBackend`, `BeamSqlBackendSyntax`][backendsql]
- [`beam-core/…/Backend/SQL/SQL92.hs` — `IsSql92Syntax` tower][sql92] · [`…/Backend/SQL/Row.hs` — `FromBackendRow`][row]
- [`beam-core/…/Query/CustomSQL.hs` — `customExpr_` raw-SQL escape hatch][customsql]
- [`beam-postgres/…/Postgres.hs` + `…/Connection.hs` — `Pg`, `runBeamPostgres`, built on `postgresql-simple`][pgmod] · [`Connection.hs`][pgconn]
- [`beam-sqlite/…/Sqlite/Connection.hs` — `SqliteM`, `runBeamSqlite`][sqlite]
- [`beam-migrate/…/Migrate.hs` + `…/Migrate/Simple.hs` — checked databases, `verifySchema`, `autoMigrate`, `bringUpToDate`][migrate] · [`Simple.hs`][migratesimple]
- [`docs/tutorials/tutorial1.md` — end-to-end schema/insert/query, injection-safety note][tut1] · [`docs/user-guide/models.md` — `Columnar`/`Nullable` rules][models]
- Concepts: [abstraction ladder][ladder] · [query construction models][qmodels] · [statements & injection][injection] · [effects, transactions & errors][effects] · [connections & pools][pools] · [type mapping][typemap] · [schema & migrations][schemamig]

<!-- References -->

[repo]: https://github.com/haskell-beam/beam
[docs]: https://haskell-beam.github.io/beam/
[docdir]: https://github.com/haskell-beam/beam/tree/98e04b09851d004a51d089db6c950bce748ea65b/docs
[readme]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/README.md
[license]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-core/LICENSE
[faq]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/docs/about/faq.md
[index]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/docs/index.md
[tables]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-core/Database/Beam/Schema/Tables.hs
[qinternal]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-core/Database/Beam/Query/Internal.hs
[combinators]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-core/Database/Beam/Query/Combinators.hs
[query]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-core/Database/Beam/Query.hs
[backendsql]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-core/Database/Beam/Backend/SQL.hs
[sql92]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-core/Database/Beam/Backend/SQL/SQL92.hs
[row]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-core/Database/Beam/Backend/SQL/Row.hs
[customsql]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-core/Database/Beam/Query/CustomSQL.hs
[pgmod]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-postgres/Database/Beam/Postgres.hs
[pgconn]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-postgres/Database/Beam/Postgres/Connection.hs
[sqlite]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-sqlite/Database/Beam/Sqlite/Connection.hs
[migrate]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-migrate/Database/Beam/Migrate.hs
[migratesimple]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-migrate/Database/Beam/Migrate/Simple.hs
[migratecabal]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/beam-migrate/beam-migrate.cabal
[tut1]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/docs/tutorials/tutorial1.md
[models]: https://github.com/haskell-beam/beam/blob/98e04b09851d004a51d089db6c950bce748ea65b/docs/user-guide/models.md
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pools]: ./concepts.md#connections-pools-and-sessions
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[schemamig]: ./concepts.md#schema-migrations-code-generation
